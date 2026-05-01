;;; capture-llm.el --- Natural language org-capture with LLM classification -*- lexical-binding: t -*-

;; Copyright (C) 2026 LI Wei

;; Author: LI Wei
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (llm "0.6.0") (org "9.0"))
;; Keywords: convenience, org, ai, llm
;; URL: https://github.com/user/capture-llm

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; capture-llm uses an LLM to automatically classify natural language input
;; and write it to the appropriate org file with correct template, tags,
;; TODO state, and scheduled/deadline times.
;;
;; Setup:
;;   (require 'capture-llm)
;;   (setq capture-llm-provider (make-llm-openai :key "sk-..."))
;;   (global-set-key (kbd "C-c C-l") 'capture-llm-capture)
;;
;; Usage:
;;   C-c C-l, type your task, press Enter.
;;   LLM classifies it and shows a preview.
;;   Press y to confirm, e to edit, n to cancel.

;;; Code:

(require 'llm)
(require 'json)
(require 'org)

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup capture-llm nil
  "Natural language org-capture with LLM classification."
  :group 'org
  :prefix "capture-llm-")

(defcustom capture-llm-provider nil
  "The llm.el provider to use for classification.
Example: (make-llm-openai :key \"sk-...\")
         (make-llm-openai-compatible :key \"...\" :url \"http://localhost:11434/v1/\")
         (make-llm-anthropic :key \"sk-ant-...\")"
  :type 'sexp
  :group 'capture-llm)

(defcustom capture-llm-categories
  '(("inbox"
     :description "Unclassified tasks"
     :file nil  ; resolved to my/org-inbox at runtime
     :heading nil
     :state "TODO"
     :tags nil)
    ("personal"
     :description "Personal tasks (appointments, shopping, errands)"
     :file nil  ; resolved to my/org-tasks
     :heading "Tasks"
     :state "TODO"
     :tags ("personal"))
    ("work"
     :description "Work tasks (meetings, reports, projects)"
     :file nil
     :heading "Tasks"
     :state "TODO"
     :tags ("work"))
    ("someday"
     :description "Non-urgent tasks for someday/maybe"
     :file nil
     :heading "Tasks"
     :state "SOMEDAY"
     :tags nil)
    ("ideas"
     :description "Thoughts, inspiration, brain dumps (not actionable)"
     :file nil
     :heading "Ideas"
     :state nil
     :tags nil)
    ("reading"
     :description "Reading notes, book reviews, articles"
     :file nil
     :heading "Reading"
     :state nil
     :tags nil))
  "Classification categories.
Each entry is (NAME :description DESC :file FILE :heading HEADING
:state STATE :tags TAGS).
FILE is a string path or a symbol whose value is a path (e.g. my/org-inbox)."
  :type '(alist :key-type string :value-type plist)
  :group 'capture-llm)

(defcustom capture-llm-tags nil
  "Available tags for classification.
If nil, auto-detected from `org-tag-alist'."
  :type '(repeat string)
  :group 'capture-llm)

(defcustom capture-llm-confirm t
  "If non-nil, show preview and ask for confirmation before writing."
  :type 'boolean
  :group 'capture-llm)

(defcustom capture-llm-extract-time t
  "If non-nil, ask LLM to extract scheduled/deadline from natural language."
  :type 'boolean
  :group 'capture-llm)

(defcustom capture-llm-system-prompt nil
  "Override the default system prompt for classification.
If nil, a sensible default is generated from category and tag config."
  :type '(choice string (const nil))
  :group 'capture-llm)

(defcustom capture-llm-temperature 0.1
  "Temperature for LLM classification. Lower is more deterministic."
  :type 'number
  :group 'capture-llm)

;;; ============================================================
;;; Internal helpers
;;; ============================================================

(defun capture-llm--get-tags ()
  "Return available tags as a list of strings."
  (or capture-llm-tags
      (mapcar (lambda (tag)
                (if (consp tag) (car tag) tag))
              org-tag-alist)))

(defun capture-llm--resolve-file (file)
  "Resolve FILE to a path string.
FILE can be a string or a symbol whose value is a string."
  (cond
   ((stringp file) file)
   ((and (symbolp file) (boundp file) (stringp (symbol-value file)))
    (symbol-value file))
   (t (error "capture-llm: Cannot resolve file: %S" file))))

(defun capture-llm--build-system-prompt ()
  "Build the classification system prompt from config."
  (or capture-llm-system-prompt
      (let* ((categories capture-llm-categories)
             (cat-desc (mapconcat
                        (lambda (cat)
                          (format "- %s: %s"
                                  (car cat)
                                  (plist-get (cdr cat) :description)))
                        categories "\n"))
             (tags (capture-llm--get-tags))
             (tag-str (string-join tags ", ")))
        (concat
         "You are a task classification assistant. "
         "Given user input, determine the category, tags, TODO state, "
         "and extract any time information.\n\n"
         "Available categories:\n" cat-desc "\n\n"
         "Available tags: " tag-str "\n\n"
         "Return JSON with these fields:\n"
         "- category: one of the category names above\n"
         "- tags: array of applicable tags (empty array if none fit)\n"
         "- todo_state: \"TODO\", \"NEXT\", \"WAITING\", \"SOMEDAY\", or null\n"
         "- title: concise task title (remove time info from title)\n"
         "- scheduled: \"YYYY-MM-DD\" or null\n"
         "- deadline: \"YYYY-MM-DD\" or null\n"
         "- notes: extra notes or null\n\n"
         "Rules:\n"
         "- If the input mentions a specific date/time, put it in scheduled\n"
         "- If it mentions a deadline/due date, put it in deadline\n"
         "- \"明天\" means tomorrow, \"下周\" means next week, etc.\n"
         "- title should be concise, without time information\n"
         "- If unsure about category, use \"inbox\"\n"
         "- Use \"ideas\" for non-actionable thoughts, set todo_state to null\n"
         "- Use \"someday\" for \"want to do someday\" type items\n"
         "- Only pick tags that genuinely apply\n"
         "- Respond with JSON only, no explanation"))))

(defun capture-llm--parse-json (text)
  "Parse JSON from TEXT, handling potential markdown code fences."
  (let ((cleaned text))
    ;; Strip markdown code fences if present
    (when (string-match "^```\\(?:json\\)?\\s-*\n\\(.*\\)\\s-*\n```$" cleaned)
      (setq cleaned (match-string 1 cleaned)))
    ;; Also try to find JSON object if there's extra text
    (unless (string-prefix-p "{" (string-trim cleaned))
      (when (string-match "\\({.*}\\)" cleaned)
        (setq cleaned (match-string 1 cleaned))))
    (json-read-from-string cleaned)))

(defun capture-llm--classify (text callback error-callback)
  "Send TEXT to LLM for classification.
Call CALLBACK with parsed JSON result on success.
Call ERROR-CALLBACK with error message on failure."
  (unless capture-llm-provider
    (error "capture-llm: `capture-llm-provider' is not set. See `capture-llm-provider' docstring"))
  (let* ((system-prompt (capture-llm--build-system-prompt))
         (prompt (llm-make-chat-prompt text
                                       :context system-prompt
                                       :temperature capture-llm-temperature
                                       :response-format 'json
                                       :max-tokens 500)))
    (llm-chat-async
     capture-llm-provider
     prompt
     (lambda (response)
       (condition-case err
           (let ((result (capture-llm--parse-json response)))
             (funcall callback result))
         (error
          (funcall error-callback
                   (format "Failed to parse LLM response: %s\nRaw: %s"
                           (error-message-string err) response)))))
     (lambda (type message)
       (funcall error-callback (format "LLM error [%s]: %s" type message))))))

(defun capture-llm--result-category (result)
  "Extract category name from RESULT."
  (or (cdr (assq 'category result)) "inbox"))

(defun capture-llm--result-tags (result)
  "Extract tags from RESULT as a list of strings."
  (let ((tags (cdr (assq 'tags result))))
    (if (vectorp tags) (append tags nil) (or tags '()))))

(defun capture-llm--result-todo (result)
  "Extract TODO state from RESULT."
  (cdr (assq 'todo_state result)))

(defun capture-llm--result-title (result)
  "Extract title from RESULT."
  (or (cdr (assq 'title result)) "Untitled"))

(defun capture-llm--result-scheduled (result)
  "Extract scheduled date from RESULT."
  (cdr (assq 'scheduled result)))

(defun capture-llm--result-deadline (result)
  "Extract deadline date from RESULT."
  (cdr (assq 'deadline result)))

(defun capture-llm--result-notes (result)
  "Extract notes from RESULT."
  (cdr (assq 'notes result)))

(defun capture-llm--category-config (category-name)
  "Get the config plist for CATEGORY-NAME."
  (cdr (assoc category-name capture-llm-categories)))

(defun capture-llm--format-org-entry (result)
  "Format RESULT into an org entry string."
  (let* ((cat-name (capture-llm--result-category result))
         (cat-cfg (capture-llm--category-config cat-name))
         (todo (or (capture-llm--result-todo result)
                   (plist-get cat-cfg :state)))
         (title (capture-llm--result-title result))
         ;; Merge LLM tags with category default tags
         (llm-tags (capture-llm--result-tags result))
         (default-tags (plist-get cat-cfg :tags))
         (all-tags (delete-dups (append llm-tags default-tags)))
         (tag-str (if all-tags
                      (concat " :" (string-join all-tags ":") ":")
                    ""))
         (scheduled (capture-llm--result-scheduled result))
         (deadline (capture-llm--result-deadline result))
         (notes (capture-llm--result-notes result))
         (parts (list
                 ;; Heading
                 (concat "* " (if todo (concat todo " ") "") title tag-str)
                 ;; Properties drawer
                 ":PROPERTIES:"
                 (concat ":CREATED: " (format-time-string "[%Y-%m-%d %a %H:%M]"))
                 ":END:")))
    ;; Scheduled
    (when scheduled
      (push (concat "SCHEDULED: <" scheduled ">") parts))
    ;; Deadline
    (when deadline
      (push (concat "DEADLINE: <" deadline ">") parts))
    ;; Body: notes
    (when (and notes (not (string-empty-p notes)))
      (push notes parts))
    ;; Reverse and join
    (string-join (nreverse parts) "\n")))

(defun capture-llm--write-entry (result)
  "Write the org entry from RESULT to the appropriate file."
  (let* ((cat-name (capture-llm--result-category result))
         (cat-cfg (capture-llm--category-config cat-name))
         (file (capture-llm--resolve-file
                (or (plist-get cat-cfg :file) 'my/org-inbox)))
         (heading (plist-get cat-cfg :heading))
         (entry (capture-llm--format-org-entry result)))
    ;; Ensure file exists
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (write-region "" nil file))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      ;; If heading specified, find it
      (when heading
        (goto-char (point-min))
        (if (re-search-forward
             (concat "^\\*+ " (regexp-quote heading)) nil t)
            (goto-char (point-at-eol))
          ;; Heading not found, create it at end
          (goto-char (point-max))
          (insert (concat "\n* " heading))))
      ;; Insert entry
      (unless (bolp) (insert "\n"))
      (insert "\n" entry "\n")
      (save-buffer)
      (message "capture-llm: Saved to %s under %s"
               (file-name-nondirectory file)
               (or heading "top level")))))

;;; ============================================================
;;; Preview
;;; ============================================================

(defvar capture-llm--preview-result nil
  "Temp storage for the result being previewed.")

(defun capture-llm--format-preview (result)
  "Format a preview string for RESULT."
  (let* ((cat-name (capture-llm--result-category result))
         (cat-cfg (capture-llm--category-config cat-name))
         (todo (or (capture-llm--result-todo result)
                   (plist-get cat-cfg :state) "—"))
         (title (capture-llm--result-title result))
         (llm-tags (capture-llm--result-tags result))
         (default-tags (plist-get cat-cfg :tags))
         (all-tags (delete-dups (append llm-tags default-tags)))
         (scheduled (or (capture-llm--result-scheduled result) "—"))
         (deadline (or (capture-llm--result-deadline result) "—"))
         (notes (or (capture-llm--result-notes result) "—"))
         (file (capture-llm--resolve-file
                (or (plist-get cat-cfg :file) 'my/org-inbox))))
    (concat
     "╔══════════════════════════════════════════╗\n"
     "║         capture-llm Preview              ║\n"
     "╚══════════════════════════════════════════╝\n\n"
     "  Category:   " cat-name "\n"
     "  File:       " (file-name-nondirectory file) "\n"
     "  Heading:    " (or (plist-get cat-cfg :heading) "(top level)") "\n"
     "  State:      " todo "\n"
     "  Title:      " title "\n"
     "  Tags:       " (if all-tags (string-join all-tags ", ") "(none)") "\n"
     "  Scheduled:  " scheduled "\n"
     "  Deadline:   " deadline "\n"
     "  Notes:      " notes "\n"
     "\n"
     "────────────────────────────────────────────\n"
     "Org entry:\n\n"
     (capture-llm--format-org-entry result) "\n"
     "\n"
     "────────────────────────────────────────────\n"
     "  y = confirm  |  e = edit entry  |  n = cancel\n")))

(defun capture-llm--preview (result)
  "Show preview buffer for RESULT, ask user to confirm.
Returns \\='confirm, \\='edit, or \\='cancel."
  (setq capture-llm--preview-result result)
  (let ((buf (get-buffer-create "*capture-llm-preview*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert (capture-llm--format-preview result))
      (goto-char (point-min))
      (special-mode)
      (display-buffer buf))
    ;; Ask user
    (let ((choice (read-char-choice
                   "Confirm? [y]es / [e]dit / [n] cancel "
                   '(?y ?e ?n ?Y ?E ?N))))
      (quit-window nil (get-buffer-window buf))
      (pcase choice
        ((or ?y ?Y) 'confirm)
        ((or ?e ?E) 'edit)
        ((or ?n ?N) 'cancel)))))

;;; ============================================================
;;; Public API
;;; ============================================================

;;;###autoload
(defun capture-llm-capture (&optional text)
  "Capture a task using natural language with LLM classification.
If TEXT is nil, prompt in the minibuffer.
The LLM classifies the input and writes it to the appropriate org file."
  (interactive)
  (let ((input (or text
                   (read-string "Capture: "))))
    (when (string-empty-p input)
      (user-error "capture-llm: Empty input"))
    (message "capture-llm: Classifying...")
    (capture-llm--classify
     input
     ;; Success callback
     (lambda (result)
       (if capture-llm-confirm
           (pcase (capture-llm--preview result)
             ('confirm
              (capture-llm--write-entry result))
             ('edit
              (let* ((entry (capture-llm--format-org-entry result))
                     (edited (read-string "Edit entry: " entry)))
                (setf (cdr (assq 'title result)) edited)
                (capture-llm--write-entry result)))
             ('cancel
              (message "capture-llm: Cancelled")))
         (capture-llm--write-entry result)))
     ;; Error callback
     (lambda (err-msg)
       (message "capture-llm: %s" err-msg)
       ;; Fallback: offer to capture manually
       (when (y-or-n-p "Classification failed.  Capture as inbox item instead? ")
         (let ((fallback-result
                `((category . "inbox")
                  (tags . [])
                  (todo_state . "TODO")
                  (title . ,input)
                  (scheduled)
                  (deadline)
                  (notes))))
           (capture-llm--write-entry fallback-result)))))))

;;;###autoload
(defun capture-llm-quick-capture (&optional text)
  "Quick capture without preview confirmation.
If TEXT is nil, prompt in the minibuffer."
  (interactive)
  (let ((capture-llm-confirm nil))
    (capture-llm-capture text)))

(provide 'capture-llm)
;;; capture-llm.el ends here

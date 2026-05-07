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
;; Optional: scan your org files once so the LLM understands your setup:
;;   M-x capture-llm-init-guide
;;
;; Usage:
;;   C-c C-l, type your task, press Enter.
;;   LLM classifies it and shows a preview.
;;   Press y to confirm, e to edit in a real buffer, c to change category, n to cancel.

;;; Code:

(require 'llm)
(require 'json)
(require 'org)
(require 'subr-x)

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
     :file my/org-inbox
     :heading "Inbox"
     :state "TODO"
     :tags nil)
    ("personal"
     :description "Personal tasks (appointments, shopping, errands)"
     :file my/org-tasks
     :heading "Tasks"
     :state "TODO"
     :tags ("personal"))
    ("work"
     :description "Work tasks (meetings, reports, projects)"
     :file my/org-tasks
     :heading "Tasks"
     :state "TODO"
     :tags ("work"))
    ("someday"
     :description "Non-urgent tasks for someday/maybe"
     :file my/org-tasks
     :heading "Tasks"
     :state "SOMEDAY"
     :tags nil)
    ("ideas"
     :description "Thoughts, inspiration, brain dumps (not actionable)"
     :file my/org-ideas
     :heading "Ideas"
     :state nil
     :tags nil)
    ("reading"
     :description "Reading notes, book reviews, articles"
     :file my/org-ideas
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

(defcustom capture-llm-examples nil
  "Few-shot examples shown in the classification prompt.
Each element is (CATEGORY-NAME . INPUT-TEXT).
Example: \\='((\"work\" . \"下周一项目汇报\") (\"personal\" . \"给老婆买花\"))"
  :type '(repeat (cons string string))
  :group 'capture-llm)

;;; ============================================================
;;; Debug
;;; ============================================================

(defvar capture-llm--debug-last-response nil
  "Last raw LLM response, for debugging.")

(defvar capture-llm--debug-last-result nil
  "Last parsed result, for debugging.")

(defun capture-llm-test (&optional text)
  "Test classification and show raw LLM output.
If TEXT is nil, prompt in minibuffer."
  (interactive)
  (let ((input (or text (read-string "Test input: "))))
    (message "capture-llm: Classifying...")
    (capture-llm--classify
     input
     (lambda (result)
       (setq capture-llm--debug-last-result result)
       (with-current-buffer (get-buffer-create "*capture-llm-debug*")
         (erase-buffer)
         (insert "=== Raw LLM Response ===\n\n"
                 capture-llm--debug-last-response
                 "\n\n=== Parsed Result ===\n\n"
                 (pp-to-string result)
                 "\n=== Org Entry ===\n\n"
                 (capture-llm--format-org-entry result))
         (goto-char (point-min))
         (display-buffer (current-buffer)))
       (message "capture-llm: Done, see *capture-llm-debug*"))
     (lambda (err)
       (message "capture-llm ERROR: %s" err)))))

;;; ============================================================
;;; Internal helpers
;;; ============================================================

(defun capture-llm--get-tags ()
  "Return available tags as a list of strings."
  (or capture-llm-tags
      (delq nil
            (mapcar (lambda (tag)
                      (let ((name (if (consp tag) (car tag) tag)))
                        (when (stringp name) name)))
                    org-tag-alist))))

(defun capture-llm--get-todo-states ()
  "Return active (non-done) TODO state strings from `org-todo-keywords'."
  (let (states)
    (dolist (seq org-todo-keywords)
      (let ((past-bar nil))
        (dolist (kw (cdr seq))
          (cond
           ((string= kw "|") (setq past-bar t))
           ((not past-bar)
            (push (replace-regexp-in-string "(.*)" "" kw) states))))))
    (or (nreverse states) '("TODO" "NEXT" "WAITING" "SOMEDAY"))))

(defvar capture-llm--org-guide nil
  "Cached org file structure description, built by `capture-llm-init-guide'.")

(defun capture-llm--resolve-file (file)
  "Resolve FILE to a path string.
FILE can be a string or a symbol whose value is a string."
  (cond
   ((stringp file) file)
   ((and (symbolp file) (boundp file) (stringp (symbol-value file)))
    (symbol-value file))
   (t (error "capture-llm: Cannot resolve file: %S" file))))

(defun capture-llm--category-is-task-p (cat-name)
  "Return non-nil if category CAT-NAME has a TODO state (i.e. is task-like)."
  (plist-get (capture-llm--category-config cat-name) :state))

(defun capture-llm--scan-org-file (file)
  "Scan FILE and return a one-line description of its top-level headings."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((fname (file-name-nondirectory file))
          headings)
      (goto-char (point-min))
      (while (re-search-forward "^\\* \\(.*\\)$" nil t)
        (let ((h (match-string-no-properties 1)))
          (setq h (replace-regexp-in-string " :[[:alnum:]_@#%:]+:[ \t]*$" "" h))
          (setq h (replace-regexp-in-string "^[A-Z]\\{2,\\} " "" h))
          (push (string-trim h) headings)))
      (format "  %s → sections: [%s]"
              fname
              (string-join (delete-dups (nreverse headings)) ", ")))))

;;;###autoload
(defun capture-llm-init-guide ()
  "Scan configured org files and cache a guide for better classification.
Call this once after configuring `capture-llm-categories'.  The guide is
included automatically in the classification prompt so the LLM understands
your org structure and can make better decisions."
  (interactive)
  (let ((seen (make-hash-table :test 'equal))
        parts)
    (dolist (cat capture-llm-categories)
      (let ((file-spec (plist-get (cdr cat) :file)))
        (when file-spec
          (condition-case nil
              (let ((file (capture-llm--resolve-file file-spec)))
                (unless (gethash file seen)
                  (puthash file t seen)
                  (when (file-exists-p file)
                    (push (capture-llm--scan-org-file file) parts))))
            (error nil)))))
    (setq capture-llm--org-guide
          (when parts
            (string-join (nreverse parts) "\n")))
    (if capture-llm--org-guide
        (message "capture-llm: Guide ready (%d file(s) scanned). Classification will use your org structure."
                 (hash-table-count seen))
      (message "capture-llm: No existing org files found to scan."))))

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
             (tag-str (if tags (string-join tags ", ") "(none configured)"))
             (todo-states (capture-llm--get-todo-states))
             (state-str (string-join todo-states " | "))
             (now (current-time))
             (today (format-time-string "%Y-%m-%d" now))
             (weekday (format-time-string "%a" now))
             (example-str
              (when capture-llm-examples
                (concat "\n## Classification examples:\n"
                        (mapconcat
                         (lambda (ex)
                           (format "- \"%s\" → %s" (cdr ex) (car ex)))
                         capture-llm-examples "\n")
                        "\n"))))
        (let* ((task-cats (mapcar #'car
                                  (seq-filter (lambda (c)
                                                (plist-get (cdr c) :state))
                                              categories)))
               (note-cats (mapcar #'car
                                  (seq-filter (lambda (c)
                                                (not (plist-get (cdr c) :state)))
                                              categories)))
               (cat-types-str
                (concat
                 "Task categories (need TODO state, may have dates): "
                 (string-join task-cats ", ") "\n"
                 "Note categories (plain notes, no TODO/dates needed): "
                 (string-join note-cats ", "))))
          (concat
           "You are a task classification assistant for Emacs org-mode.\n\n"
           "Current date: " today " (" weekday ")\n\n"
           (when capture-llm--org-guide
             (concat "## User's org file structure:\n"
                     capture-llm--org-guide "\n\n"))
           "## Categories (pick exactly one):\n" cat-desc "\n\n"
           "## Category types:\n" cat-types-str "\n\n"
           "## Available TODO states: " state-str "\n\n"
           "## Available tags: " tag-str "\n"
           "Only use tags from this list. Use empty array if none apply.\n"
           (or example-str "")
           "\n## Step 1 — Determine category.\n"
           "## Step 2 — Based on category type, fill in the JSON fields:\n\n"
           "For TASK categories, output:\n"
           "- category, tags, todo_state (one of [" state-str "]), title\n"
           "- scheduled: \"YYYY-MM-DD Day HH:MM\" or \"YYYY-MM-DD Day\" or null\n"
           "- deadline: \"YYYY-MM-DD Day HH:MM\" or \"YYYY-MM-DD Day\" or null\n"
           "- notes: extra context or null\n\n"
           "For NOTE categories, output:\n"
           "- category, tags, title, notes\n"
           "- todo_state: null, scheduled: null, deadline: null\n\n"
           "## Date/time rules (for task categories):\n"
           "- 今天=" today ", 明天=today+1, 后天=today+2, 大后天=today+3\n"
           "- 下周X=next week's X, 周X=this week's X (current weekday: " weekday ")\n"
           "- Include time when mentioned (e.g. 下午3点 → 15:00)\n"
           "- 截止/之前/前/due/by → deadline; 去做/计划/会议/见面 → scheduled\n\n"
           "## Classification rules:\n"
           "- If unsure, use \"inbox\"\n"
           "- Non-actionable thoughts, observations, journal → note category\n"
           "- \"Want to someday\" items → someday (task category)\n"
           "- Remove time expressions from title\n\n"
           "Respond with JSON only, no explanation."))))

(defun capture-llm--parse-json (text)
  "Parse JSON from TEXT, handling potential markdown code fences."
  (let ((cleaned text))
    ;; Strip markdown code fences if present
    (when (string-match "^```\\(?:json\\)?[[:space:]]*\n\\(\\(?:.\\|\n\\)*?\\)\n```" cleaned)
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
       (setq capture-llm--debug-last-response response)
       (condition-case err
           (let ((result (capture-llm--parse-json response)))
             (setq capture-llm--debug-last-result result)
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

(defun capture-llm--present-string-p (value)
  "Return non-nil when VALUE is a non-empty string."
  (and (stringp value) (not (string-empty-p value))))

(defun capture-llm--string-or-nil (value)
  "Return VALUE when it is a non-empty string, otherwise nil."
  (when (capture-llm--present-string-p value)
    value))

(defun capture-llm--category-config (category-name)
  "Get the config plist for CATEGORY-NAME."
  (cdr (assoc category-name capture-llm-categories)))

(defun capture-llm--entry-level-for-result (result)
  "Return the org heading level that RESULT will be written with."
  (let* ((cat-name (capture-llm--result-category result))
         (cat-cfg (capture-llm--category-config cat-name))
         (file (capture-llm--resolve-file
                (or (plist-get cat-cfg :file) 'my/org-inbox)))
         (heading (plist-get cat-cfg :heading))
         (level 1))
    (when heading
      (setq level 2)
      (when (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (re-search-forward
                 (concat "^\\(\\*+\\) " (regexp-quote heading)) nil t)
            (setq level (1+ (length (match-string 1))))))))
    level))

(defun capture-llm--format-org-entry (result &optional level)
  "Format RESULT into an org entry string.
LEVEL is the heading depth (default 1).
For note-type categories (no :state in config), TODO state and planning
timestamps are omitted regardless of what the LLM returned."
  (let* ((level (or level 1))
         (stars (make-string level ?*))
         (cat-name (capture-llm--result-category result))
         (cat-cfg (capture-llm--category-config cat-name))
         (is-task (capture-llm--category-is-task-p cat-name))
         ;; For note categories, suppress TODO and planning even if LLM returned them
         (todo (when is-task
                 (or (capture-llm--result-todo result)
                     (plist-get cat-cfg :state))))
         (title (capture-llm--result-title result))
         (llm-tags (capture-llm--result-tags result))
         (default-tags (plist-get cat-cfg :tags))
         (all-tags (delete-dups (append llm-tags default-tags)))
         (tag-str (if all-tags
                      (concat " :" (string-join all-tags ":") ":")
                    ""))
         (scheduled (when is-task
                      (capture-llm--string-or-nil
                       (capture-llm--result-scheduled result))))
         (deadline (when is-task
                     (capture-llm--string-or-nil
                      (capture-llm--result-deadline result))))
         (notes (capture-llm--string-or-nil (capture-llm--result-notes result)))
         (planning (string-join
                    (delq nil
                          (list (when scheduled (concat "SCHEDULED: <" scheduled ">"))
                                (when deadline (concat "DEADLINE: <" deadline ">"))))
                    " "))
         (parts (list
                 (concat stars " " (if todo (concat todo " ") "") title tag-str))))
    (when (not (string-empty-p planning))
      (setq parts (append parts (list planning))))
    (setq parts
          (append parts
                  (list ":PROPERTIES:"
                        (concat ":CREATED: "
                                (format-time-string "[%Y-%m-%d %a %H:%M]"))
                        ":END:")))
    (when notes
      (setq parts (append parts (list notes))))
    (string-join parts "\n")))

(defun capture-llm--write-entry (result)
  "Write the org entry from RESULT to the appropriate file."
  (capture-llm--write-entry-text result nil))

(defun capture-llm--write-entry-text (result entry-text)
  "Write ENTRY-TEXT for RESULT to the appropriate file.
If ENTRY-TEXT is nil, format RESULT as an org entry."
  (let* ((cat-name (capture-llm--result-category result))
         (cat-cfg (capture-llm--category-config cat-name))
         (file (capture-llm--resolve-file
                (or (plist-get cat-cfg :file) 'my/org-inbox)))
         (heading (plist-get cat-cfg :heading))
         (entry-level 1)
         entry)
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
             (concat "^\\(\\*+\\) " (regexp-quote heading)) nil t)
            (let ((parent-level (length (match-string 1))))
              (setq entry-level (1+ parent-level))
              (goto-char (line-beginning-position))
              (org-end-of-subtree t))
          ;; Heading not found, create it at end of file
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert "* " heading)
          (setq entry-level 2)))
      ;; Format entry with correct level unless caller provided edited text.
      (setq entry (or entry-text
                      (capture-llm--format-org-entry result entry-level)))
      ;; Insert entry
      (unless (bolp) (insert "\n"))
      (insert "\n" entry "\n")
      (save-buffer)
      (message "capture-llm: Saved to %s under %s"
               (file-name-nondirectory file)
               (or heading "top level")))))

(defun capture-llm--edit-in-buffer (entry)
  "Open ENTRY in a dedicated org-mode buffer for editing.
C-c C-c saves, C-c C-k cancels.  Returns edited text or nil."
  (let ((buf (get-buffer-create "*capture-llm-edit*"))
        edited)
    (with-current-buffer buf
      (erase-buffer)
      (org-mode)
      (insert entry)
      (goto-char (point-min))
      (local-set-key (kbd "C-c C-c")
                     (lambda ()
                       (interactive)
                       (setq edited (buffer-string))
                       (exit-recursive-edit)))
      (local-set-key (kbd "C-c C-k")
                     (lambda () (interactive) (exit-recursive-edit))))
    (pop-to-buffer buf)
    (message "Edit entry.  C-c C-c to confirm, C-c C-k to go back.")
    (condition-case nil (recursive-edit) (quit nil))
    (when-let ((win (get-buffer-window buf t)))
      (quit-window nil win))
    edited))

(defun capture-llm--change-category (result)
  "Interactively pick a new category for RESULT and return updated result."
  (let* ((cats (mapcar #'car capture-llm-categories))
         (chosen (completing-read "Change category to: " cats nil t))
         (new-cfg (capture-llm--category-config chosen)))
    `((category . ,chosen)
      (tags . ,(cdr (assq 'tags result)))
      (todo_state . ,(or (plist-get new-cfg :state)
                         (cdr (assq 'todo_state result))))
      (title . ,(cdr (assq 'title result)))
      (scheduled . ,(cdr (assq 'scheduled result)))
      (deadline . ,(cdr (assq 'deadline result)))
      (notes . ,(cdr (assq 'notes result))))))

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
     (capture-llm--format-org-entry
      result
      (capture-llm--entry-level-for-result result)) "\n"
     "\n"
     "────────────────────────────────────────────\n"
     "  y = confirm  |  e = edit  |  c = change category  |  n = cancel\n")))

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
                   "Confirm? [y]es / [e]dit / [c]hange category / [n] cancel "
                   '(?y ?e ?c ?n ?Y ?E ?C ?N))))
      (quit-window nil (get-buffer-window buf))
      (pcase choice
        ((or ?y ?Y) 'confirm)
        ((or ?e ?E) 'edit)
        ((or ?c ?C) 'change-category)
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
           (let ((current result)
                 (done nil))
             (while (not done)
               (pcase (capture-llm--preview current)
                 ('confirm
                  (capture-llm--write-entry current)
                  (setq done t))
                 ('edit
                  (let* ((level (capture-llm--entry-level-for-result current))
                         (entry (capture-llm--format-org-entry current level))
                         (edited (capture-llm--edit-in-buffer entry)))
                    (when edited
                      (capture-llm--write-entry-text current edited)
                      (setq done t))))
                 ('change-category
                  (setq current (capture-llm--change-category current)))
                 ('cancel
                  (message "capture-llm: Cancelled")
                  (setq done t)))))
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

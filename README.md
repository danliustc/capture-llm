# capture-llm

Natural language org-capture with LLM classification for Emacs.

Type a sentence, let the LLM figure out where it goes.

## Install

### Dependencies

- Emacs 27.1+
- [llm.el](https://github.com/ahyatt/llm) (GNU ELPA)
- Org 9.0+

```elisp
;; Install llm.el first
(use-package llm
  :ensure t)
```

### capture-llm

Clone this repo:

```bash
git clone https://github.com/user/capture-llm ~/Code/capture-llm
```

Add to your config:

```elisp
(add-to-list 'load-path "~/Code/capture-llm")
(require 'capture-llm)
```

Or with `use-package`:

```elisp
(use-package capture-llm
  :load-path "~/Code/capture-llm"
  :bind ("C-c C-l" . capture-llm-capture))
```

## Setup

### 1. Configure the LLM provider

```elisp
;; DeepSeek
(require 'llm-deepseek)
(setq capture-llm-provider
      (make-llm-deepseek :key "your-api-key"
                         :chat-model "deepseek-chat"))

;; OpenAI
(setq capture-llm-provider (make-llm-openai :key "sk-..."))

;; Anthropic (Claude)
(setq capture-llm-provider (make-llm-anthropic :key "sk-ant-..."))

;; Ollama (local)
(setq capture-llm-provider
      (make-llm-openai-compatible
       :key "ollama"
       :url "http://localhost:11434/v1/"))

;; OpenRouter
(setq capture-llm-provider (make-llm-openrouter :key "sk-or-..."))
```

### 2. Bind a key

```elisp
(global-set-key (kbd "C-c C-l") 'capture-llm-capture)
```

## Usage

```
C-c C-l            Type your task, LLM classifies it, preview, confirm
```

### Examples

| Input | Category | Tags | State | Time |
|-------|----------|------|-------|------|
| "明天下午3点去医院体检" | personal | personal, health | TODO | scheduled: 2026-05-02 Fri 15:00 |
| "下周三前交项目周报" | work | work | TODO | deadline: 2026-05-06 Wed |
| "想学摄影" | someday | — | SOMEDAY | — |
| "今天天气真好" | ideas | — | — | — |
| "给老婆买巧克力饮料" | personal | personal, errands | TODO | — |

### Preview

After classification, a preview buffer shows the result:

```
╔══════════════════════════════════════════╗
║         capture-llm Preview              ║
╚══════════════════════════════════════════╝

  Category:   personal
  File:       tasks.org
  Heading:    Tasks
  State:      TODO
  Title:      去医院体检
  Tags:       personal, health
  Scheduled:  2026-05-02 Fri 15:00
  Deadline:   —
  Notes:      —

  y = confirm  |  e = edit entry  |  n = cancel
```

Press `y` to write, `e` to edit the entry before writing, `n` to cancel.

## Default categories

| Category | File | Heading | Default State | Default Tags |
|----------|------|---------|---------------|--------------|
| inbox | inbox.org | Inbox | TODO | — |
| personal | tasks.org | Tasks | TODO | personal |
| work | tasks.org | Tasks | TODO | work |
| someday | tasks.org | Tasks | SOMEDAY | — |
| ideas | ideas.org | Ideas | — | — |
| reading | ideas.org | Reading | — | — |

Entries are inserted under the heading at the correct nesting level. For example, if `* Tasks` is a top-level heading, new entries are inserted as `**`.

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `capture-llm-provider` | nil | llm.el provider (**required**) |
| `capture-llm-categories` | GTD defaults | Category definitions (see below) |
| `capture-llm-tags` | nil (auto from `org-tag-alist`) | Available tags for classification |
| `capture-llm-confirm` | t | Show preview before writing |
| `capture-llm-extract-time` | t | Extract scheduled/deadline from input |
| `capture-llm-system-prompt` | nil (auto-generated) | Override the classification prompt |
| `capture-llm-temperature` | 0.1 | LLM temperature (lower = more deterministic) |

### Custom categories

```elisp
(setq capture-llm-categories
  '(("inbox"
     :description "Unclassified tasks"
     :file my/org-inbox
     :heading "Inbox"
     :state "TODO"
     :tags nil)
    ("personal"
     :description "Personal tasks"
     :file my/org-tasks
     :heading "Tasks"
     :state "TODO"
     :tags ("personal"))
    ;; ... add more as needed
    ))
```

Each category:
- `:file` — target org file (string path or symbol like `my/org-inbox`)
- `:heading` — heading under which to insert (entries auto-nest at the right level)
- `:state` — default TODO state (nil for non-task entries)
- `:tags` — default tags for this category
- `:description` — shown to the LLM for classification

## Debug

`M-x capture-llm-test` — test classification without writing to any file. Shows the raw LLM response, parsed result, and formatted org entry in `*capture-llm-debug*`.

## Acknowledgments

- [llm.el](https://github.com/ahyatt/llm) — provider-agnostic LLM abstraction for Emacs, the foundation of this project
- [org-mode](https://orgmode.org/) — the reason we use Emacs in the first place

Built with the help of [Xiaomi MiMo](https://github.com/XiaomiMiMo) and [OpenAI Codex](https://openai.com/index/codex/).

## License

GPL-3.0

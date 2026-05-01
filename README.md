# capture-llm

Natural language org-capture with LLM classification for Emacs.

Type a sentence, let the LLM figure out where it goes.

## Install

### Dependencies

```elisp
;; In your init.el or config.org
(use-package llm
  :ensure t)
```

### capture-llm

Clone this repo and add to your load path:

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

### 2. Configure categories (optional)

The default categories work with a standard GTD setup. To customize:

```elisp
(setq capture-llm-categories
  '(("inbox"
     :description "Unclassified tasks"
     :file my/org-inbox
     :heading nil
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

Each category maps to:
- `:file` — target org file (string path or symbol like `my/org-inbox`)
- `:heading` — heading under which to insert (nil = file top level)
- `:state` — default TODO state
- `:tags` — default tags for this category
- `:description` — shown to the LLM for classification

### 3. Bind a key

```elisp
(global-set-key (kbd "C-c C-l") 'capture-llm-capture)
```

## Usage

```
C-c C-l            Type your task, LLM classifies it, preview, confirm
C-u C-c C-l        Quick capture (skip preview)
```

### Examples

| Input | Category | Tags | State | Time |
|-------|----------|------|-------|------|
| "明天下午3点去医院体检" | personal | health | TODO | scheduled: tomorrow |
| "下周三前交项目周报" | work | — | TODO | deadline: next Wednesday |
| "想学摄影" | someday | — | SOMEDAY | — |
| "今天天气真好" | ideas | — | — | — |
| "买牛奶" | inbox | errands | TODO | — |

### Preview buffer

After classification, you'll see a preview:

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
  Scheduled:  2026-05-02
  Deadline:   —
  Notes:      —

  y = confirm  |  e = edit entry  |  n = cancel
```

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `capture-llm-provider` | nil | llm.el provider (required) |
| `capture-llm-categories` | GTD defaults | Category definitions |
| `capture-llm-tags` | nil (auto from org) | Available tags |
| `capture-llm-confirm` | t | Show preview before writing |
| `capture-llm-extract-time` | t | Extract scheduled/deadline |
| `capture-llm-system-prompt` | nil (auto-generated) | Override classification prompt |
| `capture-llm-temperature` | 0.1 | LLM temperature |

## License

GPL-3.0

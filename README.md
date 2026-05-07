# capture-llm

Type a sentence. Let the LLM decide where it goes.

capture-llm 是一个 Emacs 包，用自然语言创建 org 条目。你输入一句话，它会自动判断分类、标题、TODO 状态、标签，以及 `SCHEDULED` / `DEADLINE`，然后写入对应的 org 文件。

```text
C-c C-l
> 下周三前交项目周报
```

预览：

```text
Category:   work
File:       tasks.org
Heading:    Tasks
State:      TODO
Title:      交项目周报
Tags:       work
Deadline:   2026-05-13 Wed
```

按 `y` 确认，`e` 编辑，`c` 改分类，`n` 取消。

## Features

- 自然语言捕获 org 任务和笔记
- 自动分类、打标签、选择 TODO 状态
- 自动提取计划时间和截止时间
- 写入前预览，可编辑或改分类
- 支持快速捕获、调试分类、扫描 org 文件结构

## Install

依赖：

- Emacs 27.1+
- [llm.el](https://github.com/ahyatt/llm)
- Org 9.0+

源码安装：

```bash
git clone https://github.com/danliustc/capture-llm ~/Code/capture-llm
```

```elisp
(use-package llm :ensure t)

(use-package capture-llm
  :load-path "~/Code/capture-llm"
  :bind (("C-c C-l" . capture-llm-capture)))
```

也可以用 `package-vc`、`straight.el` 或 `elpaca` 从 GitHub 安装：

```elisp
;; Emacs 29+
(package-vc-install "https://github.com/danliustc/capture-llm")

;; straight.el
(use-package capture-llm
  :straight (:host github :repo "danliustc/capture-llm"))

;; elpaca
(use-package capture-llm
  :elpaca (:host github :repo "danliustc/capture-llm"))
```

## Configure

先配置一个 llm.el provider：

```elisp
;; OpenAI
(setq capture-llm-provider
      (make-llm-openai :key "sk-..."))

;; Anthropic
(setq capture-llm-provider
      (make-llm-anthropic :key "sk-ant-..."))

;; OpenAI-compatible，例如 Ollama 或其他兼容端点
(setq capture-llm-provider
      (make-llm-openai-compatible
       :key "your-api-key"
       :url "http://localhost:11434/v1/"))
```

默认分类会引用这几个路径变量：

```elisp
(setq my/org-inbox "~/org/inbox.org"
      my/org-tasks "~/org/tasks.org"
      my/org-ideas "~/org/ideas.org")
```

默认分类包括 `inbox`、`personal`、`work`、`someday`、`ideas`、`reading`。如果不适合你的工作流，直接重写 `capture-llm-categories`。

## Usage

```text
M-x capture-llm-capture
```

或使用绑定的快捷键：

```text
C-c C-l
```

快速捕获，不显示预览：

```text
M-x capture-llm-quick-capture
```

配置好分类后，可以运行一次：

```text
M-x capture-llm-init-guide
```

它会扫描分类中配置的 org 文件，把已有 heading 提供给 LLM 作为参考。

## Categories

一个分类长这样：

```elisp
(setq capture-llm-categories
      '(("inbox"
         :description "未分类任务，拿不准时放这里"
         :file "~/org/inbox.org"
         :heading "Inbox"
         :state "TODO"
         :tags nil)
        ("work"
         :description "工作任务、会议、项目推进、报告"
         :file "~/org/tasks.org"
         :heading "Work"
         :state "TODO"
         :tags ("work"))
        ("ideas"
         :description "想法、灵感、观察、非行动项"
         :file "~/org/notes.org"
         :heading "Ideas"
         :state nil
         :tags nil)))
```

说明：

- `:description` 给 LLM 看，用来判断分类。
- `:file` 是写入文件，可以是字符串路径，也可以是值为路径的符号。
- `:heading` 是写入位置；不存在时会自动创建。
- `:state` 决定它是不是任务分类。为 nil 时写成普通笔记。
- `:tags` 是该分类默认附加的标签。

还可以加一些示例，帮助模型贴近你的习惯：

```elisp
(setq capture-llm-examples
      '(("work" . "下周一项目汇报")
        ("personal" . "明天下午三点去医院体检")
        ("ideas" . "最近注意力太碎了，需要重新整理节奏")))
```

## Useful Options

| 变量 | 说明 |
|------|------|
| `capture-llm-provider` | llm.el provider，必填 |
| `capture-llm-categories` | 分类定义 |
| `capture-llm-tags` | 可用标签；nil 时从 `org-tag-alist` 读取 |
| `capture-llm-confirm` | 是否写入前预览 |
| `capture-llm-temperature` | 分类温度，默认 `0.1` |
| `capture-llm-examples` | few-shot 示例 |
| `capture-llm-system-prompt` | 完全覆盖默认 prompt |

## Debug

```text
M-x capture-llm-test
```

它只测试分类，不写入文件。结果会显示在 `*capture-llm-debug*`，包含原始 LLM 响应、解析后的 JSON 和最终 org entry。

## Credits

- [llm.el](https://github.com/ahyatt/llm)
- [org-mode](https://orgmode.org/)

本项目在 [Claude Code](https://claude.ai/claude-code)、[Xiaomi MiMo](https://github.com/XiaomiMiMo) 和 [OpenAI Codex](https://openai.com/index/codex/) 的帮助下完成。

## License

GPL-3.0

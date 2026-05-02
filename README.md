# capture-llm

Type a sentence. LLM decides where it goes.

capture-llm 是一个 Emacs 包，让你用自然语言做 org-capture。你只需要打一句话，LLM 会自动判断它属于哪个分类、该打什么标签、有没有时间信息，然后写入对应的 org 文件。

```
C-c C-l
> 下周三前交项目周报
```

LLM 输出：

```
Category:   work
File:       tasks.org
Heading:    Tasks
State:      TODO
Tags:       work
Deadline:   2026-05-06 Wed
```

按 `y` 确认写入，`e` 编辑，`n` 取消。

## 它解决什么问题

org-capture 模板很多，但每次都要想"这条该用哪个模板"。capture-llm 把这个决策交给 LLM：

- "明天下午3点去医院体检" -> personal / TODO / scheduled
- "想学摄影" -> someday / SOMEDAY
- "给老婆买巧克力" -> personal / errands / TODO
- "今天天气真好" -> ideas / 无状态

你只管说人话，分类的事交给模型。

## 安装

### 依赖

- Emacs 27.1+
- [llm.el](https://github.com/ahyatt/llm) (GNU ELPA)
- Org 9.0+

### 方案一：从源码安装

```bash
git clone https://github.com/danliustc/capture-llm ~/Code/capture-llm
```

```elisp
(use-package llm :ensure t)

(use-package capture-llm
  :load-path "~/Code/capture-llm"
  :bind ("C-c C-l" . capture-llm-capture))
```

### 方案二：通过包管理器安装

**Emacs 29+ (package-vc, 内置)**

```elisp
(use-package llm :ensure t)
(package-vc-install "https://github.com/danliustc/capture-llm")

(use-package capture-llm
  :bind ("C-c C-l" . capture-llm-capture))
```

**straight.el**

```elisp
(use-package llm :ensure t)

(use-package capture-llm
  :straight (:host github :repo "danliustc/capture-llm")
  :bind ("C-c C-l" . capture-llm-capture))
```

**elpaca**

```elisp
(use-package llm :ensure t)

(use-package capture-llm
  :elpaca (:host github :repo "danliustc/capture-llm")
  :bind ("C-c C-l" . capture-llm-capture))
```

### 配置 LLM 提供商

选一个你有的 API key：

```elisp
;; DeepSeek (推荐，便宜好用)
(setq capture-llm-provider (make-llm-deepseek :key "your-api-key" :chat-model "deepseek-chat"))

;; OpenAI
(setq capture-llm-provider (make-llm-openai :key "sk-..."))

;; Anthropic (Claude)
(setq capture-llm-provider (make-llm-anthropic :key "sk-ant-..."))

;; Ollama (本地模型，免费)
(setq capture-llm-provider (make-llm-openai-compatible :key "ollama" :url "http://localhost:11434/v1/"))

;; OpenRouter
(setq capture-llm-provider (make-llm-openrouter :key "sk-or-..."))
```

## 默认分类

| 分类 | 文件 | 标题 | 默认状态 | 默认标签 |
|------|------|------|----------|----------|
| inbox | inbox.org | Inbox | TODO | — |
| personal | tasks.org | Tasks | TODO | personal |
| work | tasks.org | Tasks | TODO | work |
| someday | tasks.org | Tasks | SOMEDAY | — |
| ideas | ideas.org | Ideas | — | — |
| reading | ideas.org | Reading | — | — |

## 自定义

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `capture-llm-provider` | nil | llm.el provider（必填） |
| `capture-llm-categories` | GTD 默认 | 分类定义 |
| `capture-llm-tags` | nil（从 `org-tag-alist` 自动读取） | 可用标签 |
| `capture-llm-confirm` | t | 写入前显示预览 |
| `capture-llm-extract-time` | t | 从输入中提取时间信息 |
| `capture-llm-system-prompt` | nil（自动生成） | 覆盖分类 prompt |
| `capture-llm-temperature` | 0.1 | LLM 温度 |

自定义分类示例：

```elisp
(setq capture-llm-categories
  '(("inbox"
     :description "未分类任务"
     :file my/org-inbox
     :heading "Inbox"
     :state "TODO"
     :tags nil)
    ("personal"
     :description "个人任务"
     :file my/org-tasks
     :heading "Tasks"
     :state "TODO"
     :tags ("personal"))))
```

## 用 AI 工具配置到你的 Emacs 里

你不需要手动读完所有代码再改配置。用 Claude Code 或 Codex，直接用自然语言描述你想要的效果，让 AI 帮你写配置。

### 第一步：安装项目

按上面的安装方式（源码或包管理器）把 capture-llm 装好。

### 第二步：让 AI 帮你写配置

在你的 Emacs 配置目录（`~/.emacs.d/` 或 `~/.config/emacs/`）下启动 Claude Code：

```bash
cd ~/.emacs.d
claude
```

然后直接告诉它你的情况：

> "帮我把 capture-llm 配置加到 init.el 里。我用 DeepSeek，API key 是 sk-xxx。我的 org 文件在 ~/org/inbox.org 和 ~/org/tasks.org。快捷键用 C-c c。"

Claude Code 会读你的 `init.el`，理解你现有的配置风格，然后生成一段能直接用的 elisp。

### 第三步：让 AI 帮你调分类

默认的 6 个分类不一定适合你。告诉 AI 你的需求：

> "帮我改 capture-llm 的分类，我需要：inbox（所有未分类的）、work（工作任务，带 work 标签）、life（生活琐事，带 life 标签）、reading（读书笔记，写到 reading.org）、fitness（健身记录，写到 fitness.org）。"

AI 会生成 `capture-llm-categories` 的配置，你贴进 init.el 就行。

### 第四步：让 AI 帮你改项目本身

如果你想改的不只是配置，而是这个包的行为本身，在项目源码目录下启动 Claude Code：

```bash
# 源码安装的话
cd ~/Code/capture-llm && claude
# 包管理器安装的话，找到对应目录，比如
# ~/.emacs.d/elpa/capture-llm-*  或  ~/.emacs.d/straight/repos/capture-llm/
```

然后用自然语言描述你想改什么：

- "帮我加一个分类叫 fitness，写到 fitness.org，带 health 和 exercise 标签"
- "让预览窗口按时间排序，有 deadline 的排前面"
- "把 system prompt 改成英文，我想试试英文分类效果是不是更好"
- "给预览窗口加一个 `r` 键，按 r 可以重新分类"
- "让 LLM 在分类时同时生成一个 emoji 前缀，比如 work 变成 💼 work"

AI 会直接修改源码，改完之后你用 `M-x capture-llm-test` 测试一下。

### 调试

```
M-x capture-llm-test
```

测试分类逻辑但不写入任何文件。在 `*capture-llm-debug*` 中查看原始 LLM 响应、解析结果和格式化后的 org entry。

如果 AI 改出了 bug，把 debug buffer 的内容贴给它：

> "测试失败了，这是 debug 输出：[贴内容]，帮我修一下。"

## 致谢

- [llm.el](https://github.com/ahyatt/llm) — Emacs 的 provider-agnostic LLM 抽象层，本项目的基石
- [org-mode](https://orgmode.org/) — 我们用 Emacs 的理由

本项目在 [Claude Code](https://claude.ai/claude-code)、[Xiaomi MiMo](https://github.com/XiaomiMiMo) 和 [OpenAI Codex](https://openai.com/index/codex/) 的帮助下完成。

## 许可证

GPL-3.0

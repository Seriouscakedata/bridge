# External AI agent systems — for comparison

_Кураторский список (2026). Архитектор смотрит сюда, когда ищет паттерны, которых у нас нет._
_Цель — не копировать, а **замечать пробелы** в нашей собственной архитектуре._

## AutoGen (Microsoft)
- Multi-agent conversation framework: каждый агент — роль, ведут диалог между собой.
- **Что у них есть:** `GroupChat` — N агентов одновременно обсуждают.
- **У нас (закрыто частично):** для Deep/High-Stakes задач `task_mode=synthesis`
  (Multi-Model Decision Synthesis, `lib/decision-synthesis.ps1`) — N≥3 модели дают
  слепые предложения (Codex/Claude-opus/Gemini → proposal_A/B/C), затем Judge +
  MicroDebate. Это и есть «совет» для архитектурных решений. Для рутинных задач — 1:1.
- **Паттерн:** `SelectorGroupChat` — кто следующий говорит выбирается отдельной LLM.

## LangGraph
- Граф состояний (узлы = шаги, рёбра = переходы), цикличный (loops), persistent state.
- **Что у них есть:** **first-class цикл с явными переходами** + checkpointing
  (state-сохранение в любой момент → можно restart с середины).
- **У нас:** последовательный поток с retry. Checkpoint мид-задачи появился в
  synthesis-пайплайне (каждый этап пишет артефакт в `channels/<slug>/decisions/<id>/`,
  можно возобновить с середины), но обычный код-ход всё ещё рестартует ход с нуля.

## Devin (Cognition Labs) / OpenHands / Devstral
- Полностью автономный SWE-агент: длинные многошаговые задачи, sandboxed VM.
- **Что у них:** sandboxed dev environment (Docker/VM) — мост может «попробовать»
  без риска для основной системы. **Browser+terminal+IDE** интегрированы.
- **У нас:** worktrees (есть!) + Codex `-s workspace-write` (ОС-confine записей в cwd/проект,
  с per-channel `danger-full-access`) — изоляция уровня sandbox-режима, не полноценная VM.
  Браузер-интеграция: visit.ps1 — снимок без интеракции; отдельный канал computer-control
  (`task_mode=computer_action`) даёт «руки оператора» по реальному ПК.

## MetaGPT
- Имитирует SWE-команду: PM → Architect → Engineer → QA. Каждая роль — свой агент.
- **Что у них:** **явные роли с SoD** (separation of duties); документы между ролями
  (SRS, design doc, etc.).
- **У нас:** Claude (planner) + Codex (coder) + DeepSeek-Pro (critic). Близко по духу.
  «QA как отдельная роль» теперь есть: feature-verifier (`tools/feature-verifier.ps1`),
  project-acceptance (`lib/project-acceptance.ps1`), scenario-прогон (`tools/scenario.ps1`)
  — приёмка гоняет реальные E2E/acceptance, не только ревью diff.

## BabyAGI / AgentGPT
- Самопостановка задач: агент сам генерирует следующие задачи в очередь.
- **Что у них:** task-queue с приоритизацией LLM-ом.
- **У нас:** есть бэклог + reflect генерит идеи. LLM-приоритизация теперь есть
  (`Invoke-BacklogLLMPrioritize`, `Invoke-LLM -Purpose 'prioritizer'`) поверх базовой
  формулы score=value*confidence/effort.

## OpenInterpreter
- Local code execution с natural language.
- **Что у них:** REPL-style — natural language → код → запуск → output → следующий промпт.
- **У нас:** Codex делает примерно это, но без явного REPL-цикла с пользователем.

## Aider
- Git-aware coding assistant: commits inline, conventional commit messages, dry-run.
- **Что у них:** **conventional commits как обязательный паттерн**; readable history.
- **У нас:** мы это уже делаем (видно в коммитах вроде `feat(meta): …`).

## crewAI
- Команды агентов с явными целями и delegation.
- **Что у них:** Crews + Tasks + Tools — структурированная композиция.
- **У нас:** есть план-доска (близко), но нет «команды агентов как объекта первого класса».

## SWE-agent (Princeton)
- Специализированный SWE-агент с custom action set: edit, search, navigate, run.
- **Что у них:** **специально-заточенные действия** для кодинга, не general-purpose tools.
- **У нас:** Codex имеет полный shell, но кастомные actions могли бы быть надёжнее.

---

## Известные слабые места у всех (кроме нас)
- **Самопочинка под сбой:** ни у кого почти нет «доктора», который сам диагностирует
  и исправляет систему при тяжёлой аварии. У нас это есть (лучшее, что мы построили).
- **Прозрачность для оператора:** большинство «чёрные ящики». У нас живой чат + план-доска + дайджест памяти.

## Чему точно стоит научиться (на основе текущего gap-анализа)
1. ~~**Checkpointing мид-задачи** (LangGraph)~~ — ✅ для synthesis (артефакты на диск);
   ОСТАЁТСЯ: обычный код-ход всё ещё рестартует с нуля (распространить checkpoint на него).
2. ~~**QA как отдельная роль** (MetaGPT)~~ — ✅ feature-verifier + project-acceptance + scenario
   гоняют E2E/acceptance (см. урок literary-slop-video: acceptance обязан тестировать не-fixture вход).
3. ~~**GroupChat / совет агентов** (AutoGen)~~ — ✅ Decision Synthesis (N≥3 слепых предложения + Judge)
   для Deep/High-Stakes; ОСТАЁТСЯ: расширить на большее число рутинных решений, если окупится.

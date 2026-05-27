# Travel Hotel Research Desk — детальный разбор проекта

**Путь:** `C:\Users\rafie\OneDrive\Documents\New project`
**Дата изучения:** 2026-05-26
**Канал моста:** `travel-planner` (project_root указывает на этот проект)

---

## 1. Назначение

**Travel Hotel Research Desk** — MVP мульти-агентного веб-приложения для подбора и сопровождения тревел-маршрутов. Не «чат с AI», а конвейер из десятков независимых LLM-агентов, каждый со своим промптом, моделью, схемой вывода и записью в БД.

Что делает для пользователя:
1. Принимает свободный текст брифа («Токио 14–16 июня 2026, премиум $20K, вайб Миядзаки…»).
2. Раскладывает его на структурированный запрос.
3. Параллельно ведёт **три исследовательских ветки**:
   - **hotels** — отели, виллы, премиальные подходы;
   - **restaurants** — рестораны, авторские/скрытые места;
   - **experiences** — активности, культурные/seasonal/wow-эвенты.
4. По каждой ветке проходит цикл: контекст → план запросов → multi-source поиск → дедуп → верификация сущностей → набор валидаторов → guide creator → quality critic → claim verifier.
5. Отдаёт финальный гайд с цитатами `SourceEvidence` (каждый факт привязан к источнику).
6. Запускает per-run **Travel Concierge** — диалоговый агент, который ведёт пользователя через выбор отелей, маршрут и практические действия с реальным циклом «исследовать → проверить критиком → исполнить».

---

## 2. Стек

| Слой | Технология | Версия |
|---|---|---|
| Фреймворк | Next.js (App Router) | 14.2.35 |
| UI | React + Tailwind + lucide-react | 18.3 / 3.4 |
| Язык | TypeScript (strict) | 5.7 |
| БД | SQLite + Prisma ORM | 5.22 |
| LLM (основной) | OpenAI SDK | 6.10 |
| LLM (альтернатива) | DeepSeek + Gemini (через `lib/gemini`) | — |
| Браузер-агент | Playwright | 1.59 |
| Валидация | Zod | 3.25 |
| Тесты | Vitest | 2.1 |

**Модели по умолчанию (через ENV):**
- `OPENAI_MINI_MODEL = gpt-5.4-mini` — рабочая лошадка
- `DEEPSEEK_AGENT_MODEL = deepseek-v4-pro`
- `OPENAI_CONCIERGE_MODEL` — отдельная для concierge
- `HYBRID_PROVIDER_MODE = deepseek_gemini` — переключает в гибридный режим, где web/maps-агенты идут через Gemini grounded search, а guide-агенты через mini.

---

## 3. Архитектура

### 3.1 Контракт AGENTS.md (конституция проекта, 16 правил)

Самые жёсткие требования:
- Никаких «один большой промпт изображает всех агентов» — каждый агент это **отдельный AgentRunner-вызов**.
- Каждый вывод сохраняется в БД (`AgentRun.rawOutputText` + `parsedOutputJson`).
- **Нельзя хранить hidden chain-of-thought** — только видимые summaries или структурированный вывод.
- Имена моделей нельзя хардкодить в бизнес-логике — только через ENV / `AgentConfig`.
- Mock-режим разрешён только для тестов и dev — не для production-пути.
- Каждый факт об отеле должен ссылаться на `SourceEvidence`; недостающие данные остаются `null`/`unknown`.

### 3.2 Слои кода

```
app/
  page.tsx                  — главная: BriefForm + список прогонов
  runs/[runId]/page.tsx     — детальная страница прогона
  api/agents/route.ts       — список/CRUD AgentConfig
  api/agents/[agentId]/     — конфигурация одного агента
  api/runs/                 — запуск прогонов, события, stop, rerun-agent
  api/runs/[runId]/concierge/   — диалоговый агент в рамках прогона
  api/runs/[runId]/experiences/ — отдельная ветка опытов
  api/runs/[runId]/restaurants/ — отдельная ветка ресторанов
  api/runs/[runId]/logs/        — логи всех agent runs
  api/runs/[runId]/events/      — RunEvent поток

components/                 — 17 React-компонентов:
  TravelDeskClient, AgentGrid, AgentCard, BriefForm,
  CardProfileBlocks, ResearchResultsTabs, FinalGuideView,
  DiningGuideView, ExperienceGuideView, ConciergePanel,
  PropertyComparisonTable, CandidateAuditPanel,
  AgentLogViewer, JsonViewer, RunDetailsClient, RunTimeline

lib/
  agents/
    registry.ts             — описание ВСЕХ 83 агентов (seed)
    prompts/                — 41 файл с промптами по доменам
  openai/
    agentRunner.ts          — ядро: один вызов = один AgentRun
    structuredOutput.ts     — Zod + JSON Schema валидация ответа
    client.ts, tokenUsage.ts, mockAgentOutputs.ts
  gemini/client.ts          — клиент Gemini grounded search
  workflow/                 — 22 файла оркестрации:
    orchestrator.ts             (hotels pipeline)
    restaurantOrchestrator.ts   (dining pipeline)
    experienceOrchestrator.ts   (experiences pipeline)
    graph.ts / restaurantGraph.ts / experienceGraph.ts (DAG агентов)
    candidateLifecycle.ts, deduplication.ts, scoring.ts,
    coverageContract.ts, claimVerifier.ts, evidenceIntegrity.ts,
    entityGraph.ts, premiumFit.ts, restaurantFit.ts,
    qualityClassificationChunks.ts, runState.ts,
    deterministicAgentRun.ts, agentExecutionPolicy.ts
  search/                   — 12 поставщиков поиска:
    openAIWebSearchProvider.ts, geminiGroundedSearchProvider.ts,
    mockSearchProvider.ts, iterativeHybridDiscovery.ts,
    iterativeHybridAudit.ts, branchSearchExecution.ts,
    followUpSearch.ts, anchorSearch.ts, regionalStayFormats.ts,
    searchProviderFactory.ts, searchExecution.ts, searchProvider.ts
  booking/                  — bookingAvailability.ts,
                              officialSiteAvailability.ts,
                              selectedBookingAvailability.ts
  concierge/                — actionExecutor.ts, context.ts, service.ts
  schemas/                  — 16 Zod-схем (brief, finalGuide,
                              propertyCandidate, coverage, concierge,
                              experience, restaurant, validation и др.)
  db/prisma.ts              — singleton клиент Prisma

prisma/
  schema.prisma             — 9 моделей (см. ниже)
  seed.ts                   — посев 83 AgentConfig из registry.ts
  migrations/               — история миграций
  dev.db                    — SQLite, ~527 MB (нагулянная данными)

scripts/
  db-init.mjs               — инициализация БД
  start-local.ps1           — лаунчер (вызывается из start-project.bat)
  smoke-openai-agent.ts     — smoke-тест одного агента
  hybrid-iterative-probe.ts — пробник гибридного режима
  isolated-entity-verifier-check.ts

tests/unit/                 — vitest-юниты
```

### 3.3 Модель данных (Prisma, 9 сущностей)

- `AgentConfig` — описание агента (id, name, model, reasoningEffort, prompt, outputSchema, tools, version). Версионируется.
- `Run` — один прогон по брифу. `status`, `rawBrief`, `normalizedBriefJson`, `finalGuideJson/Markdown`.
- `AgentRun` — один LLM-вызов внутри прогона. Содержит `inputJson`, `rawOutputText`, `parsedOutputJson`, `errorJson`, тайминги и **учёт токенов** (input/output/reasoning/total).
- `SourceEvidenceRecord` — цитаты из источников: URL, домен, snippet, quote, confidence.
- `PropertyRecord` — финальные сущности (отели/рестораны/опыты) с `finalScore`, `confidenceScore`, `riskLevel`.
- `RunEvent` — event stream прогона (для UI таймлайна).
- `ConciergeSession` + `ConciergeMessage` + `ConciergeAction` — состояние диалога и действий per-run.

### 3.4 Полный список 83 агентов (по доменам)

**Общие / Hotels (29):**
brief-decomposer · search-anchor-resolver · destination-context · query-planner · hotel-search-executor · hotel-coverage-contract · aggregator-searcher · direct-website-searcher · maps-searcher · forum-blog-searcher · premium-discovery-searcher · regional-signature-searcher · booking-availability-checker · hotel-search-recall-auditor · hotel-recall-followup-search · hotel-entity-graph-builder · hotel-entity-verifier · selected-booking-checker · official-site-booking-checker · candidate-deduplicator · aggregator-presence-validator · review-validator · website-validator · location-validator · risk-validator · hotel-premium-local-gem-classifier · guide-creator · hotel-guide-quality-critic · hotel-claim-verifier

**Concierge (4):**
travel-concierge · concierge-action-researcher · concierge-route-critic · concierge-practical-advisor

**Restaurants (24):**
restaurant-brief-interpreter · restaurant-dining-context · restaurant-query-planner · restaurant-search-executor · restaurant-coverage-contract · restaurant-awarded-searcher · restaurant-hidden-local-searcher · restaurant-maps-searcher · restaurant-forum-blog-searcher · restaurant-review-aggregator-searcher · restaurant-search-recall-auditor · restaurant-recall-followup-search · restaurant-entity-graph-builder · restaurant-entity-verifier · restaurant-deduplicator · restaurant-reservation-validator · restaurant-menu-price-validator · restaurant-reputation-validator · restaurant-logistics-validator · restaurant-risk-validator · restaurant-premium-local-gem-classifier · restaurant-guide-creator · restaurant-guide-quality-critic · restaurant-claim-verifier

**Experiences (26):**
experience-brief-interpreter · experience-context · experience-query-planner · experience-search-executor · experience-coverage-contract · experience-classic-searcher · experience-outdoor-adventure-searcher · experience-rare-wow-searcher · experience-premium-private-searcher · experience-culture-craft-searcher · experience-event-seasonal-searcher · experience-maps-searcher · experience-deep-forum-searcher · experience-search-recall-auditor · experience-recall-followup-search · experience-entity-graph-builder · experience-entity-verifier · experience-deduplicator · experience-availability-validator · experience-reputation-validator · experience-logistics-validator · experience-risk-validator · experience-premium-local-gem-classifier · experience-guide-creator · experience-guide-quality-critic · experience-claim-verifier

Заметна **зеркальная архитектура**: все три домена идут одной канвой (interpreter → context → planner → multi-source searcher → recall audit → dedup → entity-graph + verifier → набор validators → guide creator + quality critic + claim verifier).

### 3.5 Поток одного прогона (hotels-ветка)

```
brief → brief-decomposer → search-anchor-resolver → destination-context
     → query-planner → [aggregator/direct/maps/forum/premium/regional searcher] (parallel)
     → hotel-search-recall-auditor → hotel-recall-followup-search (если recall провален)
     → hotel-entity-graph-builder → hotel-entity-verifier
     → candidate-deduplicator
     → [aggregator-presence/review/website/location/risk validators] (parallel)
     → hotel-premium-local-gem-classifier
     → booking-availability-checker → selected-booking-checker → official-site-booking-checker
     → guide-creator → hotel-guide-quality-critic → hotel-claim-verifier
     → finalGuide (JSON + Markdown)
```

Параллельно (если запрошено в брифе) идут такие же пайплайны для restaurants и experiences. После всех прогонов Concierge подхватывает результат и ведёт диалог.

---

## 4. Файлы / точки входа

- **Запуск (Windows one-click):** `start-project.bat` → `scripts\start-local.ps1` → готовит SQLite, сидит конфиги, поднимает Next.js на `http://localhost:3000`.
- **Запуск (ручной):** `npm install` → `npm run db:push` → `npm run db:seed` → `npm run dev`.
- **Без оплаты OpenAI:** `OPENAI_MOCK_MODE=true npm run dev` — все агенты отдают замоканный вывод.
- **Главный UI-вход:** `app/page.tsx` → `<TravelDeskClient/>` → `<BriefForm/>` + `<AgentGrid/>`.
- **Детальный UI прогона:** `app/runs/[runId]/page.tsx` → `<RunDetailsClient/>` + `<AgentLogViewer/>` + `<ConciergePanel/>` + `<ResearchResultsTabs/>`.
- **Ядро запуска агента:** `lib/openai/agentRunner.ts`.
- **Оркестратор отельной ветки:** `lib/workflow/orchestrator.ts`.

---

## 5. Как использовать

1. Двойной клик `start-project.bat` (или `npm run dev`).
2. Открыть `http://localhost:3000`.
3. Ввести бриф вида «Куда, когда, бюджет, вайб, ограничения».
4. Дождаться завершения прогона (event stream показывает RunEvent'ы в реальном времени).
5. На странице прогона:
   - вкладка финального гайда (hotels / restaurants / experiences);
   - таблица сравнения, карточки;
   - панель Concierge — продолжить диалогом (выбрать отель → построить маршрут → практический совет).
6. Если результат сомнительный — кнопка «rerun-agent» позволяет переиграть отдельного агента, не пересчитывая весь прогон.

---

## 6. Зависимости

**Внешние сервисы (опционально, через ENV):**
- OpenAI API (`OPENAI_API_KEY`) — основной провайдер.
- DeepSeek API — альтернатива OpenAI.
- Gemini API — grounded web/maps search в гибридном режиме.
- Playwright — реальные проверки доступности на сайтах (booking.com, официальные сайты отелей, рестораны).

**Локально:**
- Node 18+, SQLite (через better-sqlite3/Prisma).
- Браузеры Playwright (chromium).

---

## 7. Состояние работ

- **Коммитов в `master`:** 2.
  - `1a36853` Initial commit: Travel Hotel Research Desk MVP
  - `08e7726` Improve hybrid workflow quality and UI usability
- **Незакоммиченное:** только runtime-артефакты (`tmp_*.png` — скрины аудитов UI, `tmp-*.png`, `dev-server.log`, `lan-server.log`, `tmp-run-status*.json`). Кода без коммита нет.
- **PLANS.md:** 1844 строки, 25+ `ExecPlan Addendum'ов` (Result Table Layout, Hotel Recovery Universalization, Booking Adapter, Premium Segment Gate, Regional Signature Stay, Official Site Booking, Universal Booking Probe, Search Anchor, Parallel Restaurants, Parallel Experiences, Per-Run Concierge, Wow/Signature Classification, Candidate Lifecycle, Search Audit Layer, Cross-Branch Recall, Branch-Selectable UX, Concierge Real Action Loop, Concierge Practical Advisor, Rich Recommendation Cards, Concierge Place Drawer, DeepSeek Provider Experiment).

**Объём БД и предыдущая статистика** (по предыдущему study-замеру): ~51 прогон, ~7330 LLM-вызовов, ~1738 объектов, ~11 200 цитат, ~89.4 M токенов. Текущий размер `dev.db` — **527 MB** (был 552 — слегка ужалась, возможно после vacuum или удалений).

---

## 8. Сильные стороны

- **Контракт AgentRun**: каждое LLM-обращение — отдельная запись с inputJson/outputJson/токенами. Полная аудируемость.
- **Версионируемые промпты** в `lib/agents/prompts/` — централизованно, не размазаны по коду.
- **Зеркальная архитектура** трёх доменов (hotels/restaurants/experiences) — структурный паттерн, удобно расширять (можно добавить ветку «transport» или «events» по тому же шаблону).
- **Claim verifier + Quality critic** в каждой ветке — два слоя независимого ревью результатов.
- **Search recall auditor + follow-up** — самопроверка полноты охвата.
- **Source Evidence** с confidence — каждый факт привязан к источнику, ничего «из головы».
- **Гибкость провайдеров** — переключение OpenAI ↔ DeepSeek ↔ Gemini через ENV без правок кода.
- **Mock-режим** изолирован для dev и тестов — продакшен-путь не мокается.

## 9. Риски и слабые места

- **Только 2 коммита в репозитории** — вся история разработки потеряна (тяжело откатывать, нет blame по причинам решений). Watchdog при поломке не сможет откатиться на «зелёный» коммит — он один.
- **dev.db в репозитории на 527 MB** — раздулась рантайм-данными, должна быть в `.gitignore`, иначе любой `git push` забьёт remote.
- **Десятки `tmp_*.png` в корне** — runtime-следы аудита UI, замусоривают рабочее дерево. Должны лежать в `tmp/` или быть очищены.
- **83 агента — это много**: при платных вызовах OpenAI один прогон может стоить $2–10. Smoke-тест без mock-режима опасен.
- **PLANS.md уже 1844 строки** — превращается в простыню. По стандартам моста подобные летописи лучше резать на файлы по эпикам.
- **AGENTS.md правило «не хранить hidden CoT»** — нужно следить, чтобы новые промпты не запрашивали reasoning trace в `rawOutputText`. Это лёгкая лазейка для будущего бага приватности.
- **`tsconfig.tsbuildinfo` тоже коммитится?** — если да, нужно убрать.

## 10. Альтернативы / что можно улучшить

- **Векторное хранилище для PropertyRecord** — сейчас дедуп по `normalizedName`, можно перейти на embeddings для семантической дедупликации брендов («Aman Tokyo» vs «アマン東京»).
- **GraphQL/tRPC вместо REST `/api/runs/*`** — упростит контракт между Next.js фронтом и API.
- **Background queue (BullMQ/pg-boss)** для долгих прогонов — сейчас, видимо, всё в процессе Next.js, что хрупко при перезапуске.
- **Отдельный read-replica** для PLANS.md/AGENTS.md как контекста агентов — чтобы конституция всегда подмешивалась в системный промпт.
- **Парный `master` ↔ `dev` workflow** — сейчас всё в одной ветке, любая правка моментально в master.

---

## 11. Источники (локальные)

[[FINDING: AGENTS.md | 16 non-negotiable rules + engineering rules + ExecPlans + Commands]]
[[FINDING: package.json | Next 14.2.35 + Prisma 5.22 + OpenAI 6.10 + Playwright 1.59 + Zod 3.25 + Vitest 2.1]]
[[FINDING: prisma/schema.prisma | 9 моделей: AgentConfig, Run, AgentRun, SourceEvidenceRecord, PropertyRecord, RunEvent, ConciergeSession, ConciergeMessage, ConciergeAction]]
[[FINDING: lib/agents/registry.ts | 83 уникальных agent ID; модели через ENV (OPENAI_MINI_MODEL=gpt-5.4-mini, DEEPSEEK_AGENT_MODEL=deepseek-v4-pro); hybrid mode переключатель HYBRID_PROVIDER_MODE=deepseek_gemini]]
[[FINDING: lib/agents/prompts/ | 41 файл промптов]]
[[FINDING: lib/workflow/ | 22 файла оркестрации: 3 orchestrator'а (hotel/restaurant/experience), 3 graph'а, candidateLifecycle, deduplication, scoring, claimVerifier, coverageContract, entityGraph, evidenceIntegrity, premiumFit, restaurantFit, qualityClassificationChunks, runState]]
[[FINDING: lib/search/ | 12 поставщиков поиска: openai web search, gemini grounded, iterative hybrid discovery/audit, anchor, follow-up, regional, mock]]
[[FINDING: app/api/runs/ | 11 REST-роутов: list, GET/POST runs, concierge, events, experiences, restaurants, logs, rerun-agent, stop]]
[[FINDING: components/ | 17 React-компонентов с TravelDeskClient в роли корневой клиентской обёртки]]
[[FINDING: README.md | Lаунчер start-project.bat готовит SQLite, сидит конфиги, поднимает Next.js на :3000; OPENAI_MOCK_MODE=true для dev без оплаты]]
[[FINDING: git log | 2 коммита: 1a36853 Initial + 08e7726 Improve hybrid workflow]]
[[FINDING: prisma/dev.db | 527 MB рантайм-данные]]
[[FINDING: PLANS.md | 1844 строки, 25+ ExecPlan Addendum'ов, ведётся Progress Log]]

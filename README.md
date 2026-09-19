# Card Rift: Co-op Dungeon ⚔️🃏

A modern **Multiplayer Co-op Roguelike Deckbuilder RPG** built for **Roblox** using [Rojo](https://rojo.space/) and strict Luau (`--!strict`).

Up to 4 players form an adventuring party, choose from 10 distinct RPG Hero classes and 20 specialized subclasses, construct custom persistent decks, unlock passive skill trees, equip gear, slot active skills, scale a 4-Act procedural Spire, collect game-altering relics, explore interactive 3D event chambers, navigate elemental battlefields, and battle synchronized 3D raid bosses in real time.

---

## 🚀 Current Project Status: Phase 4 Persistent Decks, Deck Builder Frontend, 3D Rooms / Events / Merchant / Campfire, Reaction V2 & Server Hardening

The current codebase implements and hardens the following foundational pillars:
* **Phase 4 Persistent Collection & Decks (`CardCollectionService.luau`, `DeckService.luau`, `PersistenceService.luau`)**: Profile versioning (`ProfileVersion = 1`), permanent card collection ownership tracking, configurable deck slot entitlements (4 base, up to 20), class-agnostic saved decks (`classId = nil`), and deterministic active deck fallback.
* **Deck Builder Frontend (`UIController.client.luau`)**: 3-column interactive modal interface, client-side draft editing with legal bounds validation (8–30 cards, max 3 copies), collection browser with search filter, and authoritative remote synchronization.
* **3D Physical Room Streaming & Encounters (`WorldRoomService.luau`, `EventService.luau`, `RunManager.luau`)**: Physical room geometry lifecycle streaming (`Workspace.CardRiftWorld.ActiveRoom`), interactive co-op event puzzles, shared merchant party stock with double-purchase concurrency locks, campfire choice semantics (Rest vs. Leave), and two-stage failure injection state rollbacks.
* **Reaction V2 & 3D Attack Presentation (`ReactionService.luau`, `CombatVFXController.client.luau`)**: Real-time 3D attack reactions without rhythm rings or approach circles. Players react visually to 3D enemy windups, jump arcs, projectile flights, and AoE telegraphs using C (Dodge) and V (Parry) with bounded latency compensation.
* **Server-Authoritative Invariants & Hardening (`DeckService.luau`, `init.server.luau`, `RunManager.luau`)**: Server-authoritative deck deletion rules (strictly rejecting deletion of sole or active decks), mid-run mutation boundary guards outside Lobby (`Phase ~= "Lobby"`), and fail-closed card grant test seams with zero persistence side effects.
* **Core Combat & RPG Subsystems (`CombatService.luau`, `DamagePipeline.luau`, `ClassService.luau`)**: Decoupled combat execution, dynamic co-op HP scaling, multi-enemy support, equipment/stat/skill/passive services, and 8 implemented class combat gimmicks (with remaining gimmicks reserved on the roadmap).

### 🧪 Verification Baseline
* **76 In-Game Integration Suites** in `TestRunner.luau` (244 test assertions in Suite 76 alone, hundreds of assertions across all suites) covering state machines, combat mechanics, room transactions, failure injection rollback, and deterministic timing math.
* **Offline verifier contains 1,429 checks** in `tests/verify_phase1_integration.py`; runtime execution must be performed locally/Studio.
* **Authoritative Build Fingerprint**: `BUILD_ID = "hardened_server_deck_contracts_20260919"` (`Hardened Server Deck Invariants & Contracts`).
* **Strict Luau (`--!strict`)** across 100% of all 45 project modules.
* **Zero `_G` Global Pollution** across the entire codebase.
* **Clean Rojo compilation** (`rojo build -o build.rbxl` exits code 0).
* **Static & Offline vs. In-Game & Interactive Verification**: Offline verification (`tests/verify_phase1_integration.py` and `luau-compile.exe`) guarantees schema, condition semantics, and contract invariants; in-game automated testing (`TestRunner.luau`) validates runtime transactions and state recovery on boot; 3D visual rendering and reaction feel are verified interactively in Roblox Studio using developer commands (`/SlowHeavy`, `/FastDagger`, `/JumpAttack`, `/ProjectileBolt`, `/UnreactableExplosion`).

---

## 🌟 Key Features & Subsystems

### 1. 10 Core Classes & 20 Subclasses (`ClassData.luau`, `ClassService.luau`)
Every class features unique base stats, starting decks, passive skill trees, and combat mechanics:
* **Warlord** (`⚔️`, 110 HP, 3 ⚡) — *Rage*: Gains +1 ATK per 10% missing HP.
  * *Berserker*: +4 flat damage when below 50% HP.
  * *Titan*: Starts combat with +10 Shield and +10 Max HP.
* **Shadowblade** (`🗡️`, 85 HP, 3 ⚡) — *Combo*: Escalating +2 effect per consecutive card played.
  * *Assassin*: 3rd card each turn is a guaranteed 2x Critical Strike.
  * *Venomancer*: All cards inflict +1 Poison.
* **Aether Mage** (`🔮`, 80 HP, 4 ⚡) — *Overload*: Unspent energy converts to Overload charges (+4 spell damage).
  * *Pyromancer*: Overload charges detonate for 5 AoE damage at turn end.
  * *Cryomancer*: Overload charges grant +4 Shield each at turn end.
* **Necrobinder** (`💀`, 90 HP, 3 ⚡) — *Souls*: Defeated enemies grant soul tokens to summon Bone Servants (8 ATK).
  * *Reaper*: Kills grant 2 souls and heal 6 HP.
  * *Swarm Lord*: Cap 15 souls; sustains multiple Bone Servants.
* **Mechanist** (`⚙️`, 95 HP, 3 ⚡) — *Gears*: Playing cards generates scrap to construct automated Sentry Turrets (6 DMG/turn).
  * *Artificer*: Turrets grant +4 Shield to the party each turn.
  * *Demolitionist*: Turrets detonate for 15 area damage upon expiration.
* **Gambler** (`🎲`, 90 HP, 3 ⚡) — *Luck Rolls*: 50%–175% damage variance; coin flips double damage on Heads.
  * *High Roller*: Coin flip winning probability increased to 70%.
  * *Card Sharp*: Rolling maximum damage refunds card Energy cost.
* **Chronomancer** (`⏳`, 85 HP, 3 ⚡) — *Rewind*: Tracks recent events to undo damage or duplicate cards.
  * *Paradox*: Duplicated cards trigger secondary effects twice.
  * *Decay*: Accelerates enemy poison ticks by 2x each turn.
* **Plague Doctor** (`☣️`, 90 HP, 3 ⚡) — *Infection*: Poison ticks splash contagion damage across all enemies.
  * *Toxicologist*: Poison stacks do not decay by 1 at end of turn.
  * *Apothecary*: 50% of all poison damage dealt heals the party.
* **Blood Priest** (`🩸`, 120 HP, 3 ⚡) — *Sacrifice*: Bypasses 0 Energy by sacrificing 5 HP per energy (+3 damage).
  * *Zealot*: Sacrificing HP below 50% grants 10 Shield.
  * *Inquisitor*: Every 15 HP sacrificed triggers an 18 damage unholy shockwave.
* **Beastmaster** (`🐺`, 95 HP, 3 ⚡) — *Pact*: Fights alongside an evolving Spirit Wolf companion (40 HP, 6 ATK).
  * *Predator*: Wolf attacks inflict Bleed / +25% damage vulnerability.
  * *Symbiote*: Wolf absorbs 50% of incoming damage directed at the hero.

> [!NOTE]
> **Class Implementation & Combat Gimmick Roadmap Status**:
> - **Fully Implemented in Combat Engine (`ClassService.luau`)**: Warlord (*Rage* & *Berserker*), Shadowblade (*Combo*, *Assassin* crits, *Venomancer* poison), Aether Mage (*Overload*, *Pyromancer* burst, *Cryomancer* shields), Blood Priest (*Sacrifice* HP for energy, *Zealot* shields, *Inquisitor* shockwaves), Gambler (*Luck Rolls*, *High Roller* coin flips, *Card Sharp* refunds), Mechanist (*Gears* scrap generation, *Sentry Turrets*, *Artificer* shields), Necrobinder (*Soul Tokens*, *Reaper* healing, *Bone Servants*), and Beastmaster (*Spirit Wolf* turn-end attack companion).
> - **Roadmap Class Gimmicks**: Chronomancer (*Rewind* timeline undo & *Paradox* card loops), Plague Doctor (*Infection* contagion poison splash & *Apothecary* healing), and Beastmaster advanced subclass perks (*Predator* vulnerability & *Symbiote* damage interception) are designed in `ClassData.luau` schemas and scheduled for future combat expansions without stub pollution.

---

### 2. Procedural 4-Act Spire (`DungeonMap.luau`, `DungeonService.luau`)
* **4 Acts**: *The Ashen Threshold*, *The Sunken Catacombs*, *The Obsidian Spire*, *The Heart Summit*.
* **10 Tiers per Act**: Normal Combat, Elite Encounters, Event Chambers, Campfire Rests, Merchant Shops, and Act Bosses.
* **Consensus Navigation**: Reachability graph validation allowing party members to vote on branch traversal.

---

### 3. Decoupled Combat Engine (`CombatService.luau`)
* **Dynamic Co-op Scaling**: $\text{ScaledHP} = \text{BaseHP} \times (1 + 0.65 \times (\text{Players} - 1))$.
* **Multi-Enemy Encounters**: Keyed collection `Enemies: { [string]: EnemyState }` supporting 1 to $N$ combatants.
* **Authoritative Pipelines**:
  * `DamagePipeline.luau`: Multi-phase damage, armor/shield absorption, piercing damage, and downed handling.
  * `StatusService.luau`: Poison, Ignite, Chill, Freeze, Shock, Bleed with distinct definitions and instances.
  * `EffectResolver.luau`: Generic, data-driven effect handlers with recursion depth limits.
  * `TargetResolver.luau`: Authoritative target validation (`Enemy`, `Self`, `Ally`, `None`).
  * `ModifierResolver.luau`: Deterministic math `(Base + Add) * Mult` with absolute override precedence.
* **Synchronized Turn System**: Monotonic 45-second countdown with player ready voting and automated timeout execution.
* **Downed & Rescue Mechanics**: Heroes at 0 HP enter a downed state; teammates spend 2 Energy to rescue with 25% Max HP.

---

### 4. RPG Character Systems (Phase 3)
* **Equipment System (`EquipmentService.luau`)**:
  * Definition vs. Instance separation.
  * Slot constraints (`Weapon`, `Armor`, `Accessory1`, `Accessory2`).
  * Authoritative server inventory validation rejecting forged items.
* **Centralized Stat Resolution (`StatResolver.luau`)**:
  * Unified calculation for all 9 stats (`Damage`, `Shield`, `ShieldGain`, `Healing`, `Cost`, `MaxHP`, `MaxEnergy`, `CritChance`, `CritMultiplier`).
* **Active Skills (`SkillService.luau`, `SkillData.luau`)**:
  * Slotted non-card abilities (`Skill1`..`Skill4`) with cooldowns, resource costs, and transactional execution.
* **Passive Class Trees (`PassiveService.luau`, `PassiveData.luau`)**:
  * Directed acyclic graph (DAG) trees with cycle detection and prerequisite enforcement.

---

### 5. Persistent Meta-Progression & Deck Builder (Phase 4 & 4.1)
* **Versioned Account Profile (`PersistenceService.luau`)**:
  * Schema versioning (`ProfileVersion = 1`) with automatic migration and reconciliation.
  * Fail-closed architecture with explicit load states (`NotLoaded`, `Loaded`, `New`, `LoadFailed`, `Saving`).
  * DataStore load failures abort without overwriting existing accounts.
  * `UpdateAsync` concurrency protection prevents stale sessions from overwriting newer remote timestamps.
* **Permanent Card Collection (`CardCollectionService.luau`)**:
  * Permanent ownership tracking (`{ [cardDefId]: count }`).
  * Test failure injection seam (`setFailureInjectionForTesting`) validating fail-closed card grant rollback semantics without side effects.
* **Deck Management (`DeckService.luau`)**:
  * Server-generated GUIDs for persistent decks.
  * Configurable slot entitlements (`BaseDeckSlots = 4`, expandible up to 20).
  * Authoritative validation: collection ownership, max 3 copies per card, 8–30 card deck bounds, class-agnostic decks (`classId = nil` by default).
  * Server-authoritative deck deletion: rejects deleting the sole remaining deck and the currently active deck, strictly preserving `ActiveDeckId` and deck counts without profile mutations; deleting inactive decks succeeds cleanly.
  * Mid-run mutation boundary: `DeckService` and `init.server` strictly reject all deck mutations (`CreateDeck`, `RenameDeck`, `DeleteDeck`, `SaveDeck`, `DuplicateDeck`, `SelectActiveDeck`) during active dungeon runs outside Lobby (`Phase ~= "Lobby"`).
  * Deterministic active-deck fallback: resolves first valid playable deck or default class starter deck with zero persistence mutation on read/fallback.
  * Strict run isolation: in-combat card movement never mutates persistent decks.

---

### 6. Reaction V2 — 3D Attack Reaction System
* **No Approach Circles**: The rhythm/OSU-style shrinking circle UI is completely removed.
* **3D Visual Cues**: Melee lunges, jump arcs, projectile flights, and expanding AoE telegraphs are rendered in the 3D world by `CombatVFXController`.
* **Authoritative Server Timing**: Server establishes `AttackStartServerTime`, `ImpactServerTime`, and `ReactionCloseServerTime` via `Workspace:GetServerTimeNow()`.
* **Controls**: `C` = Dodge, `V` = Parry. Space and Shift are explicitly unbound.
* **Bounded Latency Compensation**: The server evaluates client input timestamps within strict physical bounds:
  * Maximum packet arrival grace: 0.20s beyond close time for network transit.
  * Future skew tolerance: 0.15s anti-spoofing limit.
  * Past lag tolerance: 0.60s stale packet rejection.

---

### 7. Centralized Network Gateway (`NetworkService.luau`)
* Centralized under `ReplicatedStorage.GameNetwork`.
* 25 RemoteEvents categorized into token-bucket rate limiters (`Combat`, `Map`, `Class`, `General`).
* Zero client authority: server injects sender identity from `player.UserId`; client cannot forge requests.
* Single authoritative `CombatStateUpdate` remote consumed by both `UIController` and `CombatVFXController`.

---

### 8. Hardened Room Lifecycle, Choices & Merchant Transactions (`RunManager.luau`)
* **Campfire Choice Semantics & Disconnected Member Rule**:
  * `Rest`: Restores 30% Max HP to connected party members (`m.IsConnected ~= false`), sets `CampfireUsed = true`, idempotently clears node, cleans room geometry, increments `StateRevision`, and transitions run to `MapSelect`. Disconnected party members receive zero healing.
  * `Leave`: Exits without resting (0 healing, `CampfireUsed` remains false), clears node, cleans room, and transitions to `MapSelect`.
  * Invalid choices: Cleanly rejected (`return false, err`) with fail-closed guarantee (zero healing, node uncleared, phase remains `ActiveRoom`).
* **Authoritative Merchant Purchasing & Shared Party Stock**:
  * **Shared Party Stock**: In co-op, merchant stock is shared across the party (stock = 1 per ware). Player A purchasing an item marks `IsPurchased = true`, locking out Player B.
  * **Double-Purchase Prevention & Concurrency Locking**: In-memory lock keyed by `runId:itemId` serializes concurrent purchase attempts and rejects simultaneous actions with in-progress notifications.
  * **Fail-Closed Card Grant Ordering**: `CardCollectionService.grantCard()` is verified and granted before deducting player gold or modifying the runtime deck. Any grant failure aborts without mutating gold, deck, or ware status.
  * **Deterministic Shop Inventory**: Wares are generated deterministically from `(seed, act, tier, nodeId)` using 32-bit polynomial string hashing (`hashStringToSeed`) and bitwise mixing.
* **Two-Stage Combat Failure Injection & State Rollback**:
  * Stage 1: Pre-setup failure injection testing initial parameter validation and abort.
  * Stage 2: Post-card-draw and resource initialization failure injection, verifying caller `RunManager.travelToNode` cleanly rolls back party HP, Shield, Energy, Hand, Deck, Discard, Exhaust, and downs status, resets `activeCombat = nil`, cleans room geometry, and keeps the run in `MapSelect`.

---

### 9. Deck Builder UI & Card Collection Frontend (`UIController.client.luau`)
* **3-Column Modal Interface**:
  * **Column 1 (Decks Sidebar)**: Displays player saved decks with slot entitlement (`Slots: X/Y`), active deck marker (`★ ACTIVE`), card count badge, `+ New Deck`, `Set Active`, `Rename`, `Duplicate`, and `Delete` controls with protection against deleting the active or sole deck.
  * **Column 2 (Draft Deck Editor)**: Dynamic card counter with color-coded bounds (`Cards: X / 30 (Min: 8, Max: 30)`), real-time deck legal status, draft cards list with `[-]`, `[+]`, `[✕]` controls, `Clear Deck`, `Revert Changes`, and `SAVE DECK 💾`.
  * **Column 3 (Collection Browser)**: Live search filter, owned cards list with card cost, name, target, and description, owned copies vs draft copies count, and contextual `+ Add to Deck` button (disabled on max deck size, copy limit, or unowned).
* **Client-Side Draft Editing**:
  * Client edits are isolated to a local draft dictionary (`currentDraftCards`) until explicit save.
  * Server rejection keeps the local draft intact without wiping unsaved changes.
* **Fail-Closed ActiveRoom UI Routing**:
  * If `Phase == "ActiveRoom"` but `roomType` is nil or unrecognized, all room frames remain hidden, status is set to `"Synchronizing room state..."`, and client issues `RequestStateSyncEvent:FireServer()` instead of defaulting to Combat.
* **Server-Side Reward Claim Concurrency Locking**:
  * `RunManager.claimRewardCard` serializes concurrent claim attempts using per-player lock keyed by `runId:userId`, rejecting rapid duplicate clicks while asynchronously executing runtime card creation and permanent collection grants.

---

## 📁 Repository Structure

```text
spire-game/
├── default.project.json          # Rojo project mapping configuration
├── README.md                     # Project overview and documentation index
├── ARCHITECTURE.md               # Master system architecture specification
├── STATE_SCHEMA.md               # Authoritative runtime and persistent data schemas
├── NETWORK_CONTRACTS.md          # Complete network RemoteEvent contract catalog
├── PERSISTENCE_SCHEMA.md         # DataStore profile, migrations, and concurrency safety
├── DECK_SYSTEM.md                # Deck model, slot entitlements, and validation rules
├── CARD_COLLECTION.md            # Permanent collection ownership and grant APIs
├── PHASE_4_IMPLEMENTATION.md     # Phase 4 & 4.1 implementation and verification record
│
├── src/
│   ├── shared/                   # ReplicatedStorage.Shared
│   │   ├── StateTypes.luau       # Canonical Luau type definitions (--!strict)
│   │   ├── GameConfig.luau       # Global game constants, limits, and scaling curves
│   │   ├── BuildInfo.luau        # Authoritative build fingerprinting
│   │   ├── CardData.luau         # Card library with data-driven effects
│   │   ├── ClassData.luau        # 10 Classes, 20 Subclasses, starting decks
│   │   ├── RelicData.luau        # 18 Relics, rarities, and trigger hooks
│   │   ├── DungeonMap.luau       # 4-Act, 10-Tier procedural Spire tree generator
│   │   ├── EquipmentData.luau    # RPG Equipment catalog and stat modifiers
│   │   ├── SkillData.luau        # Active skills catalog and costs
│   │   ├── PassiveData.luau      # Passive skill trees (DAG) and prerequisites
│   │   ├── ReactionData.luau     # 3D attack timing profiles and projectile resolver
│   │   ├── EventData.luau        # 3D interactive co-op event definitions and riddles
│   │   └── EnvironmentData.luau  # Elemental affinities and battlefield transformations
│   │
│   ├── server/                   # ServerScriptService.Server
│   │   ├── init.server.luau      # Authoritative server bootstrap & remote dispatch
│   │   └── services/             # Discrete service modules (--!strict)
│   │       ├── NetworkService.luau        # Centralized gateway & token-bucket rate limiter
│   │       ├── PersistenceService.luau    # Fail-closed DataStore, migrations, UpdateAsync
│   │       ├── CardCollectionService.luau # Permanent card collection ownership
│   │       ├── DeckService.luau           # Deck CRUD, slot entitlements, validation
│   │       ├── RunManager.luau            # RunState SSOT & expedition lifecycle
│   │       ├── CombatService.luau         # CombatState SSOT & turn orchestration
│   │       ├── CardService.luau           # Runtime CardInstance synthesis & piles
│   │       ├── ClassService.luau          # Hero classes, starting decks, gimmicks
│   │       ├── RelicService.luau          # Relic inventory & passive triggers
│   │       ├── DungeonService.luau        # Procedural map lifecycle & voting
│   │       ├── EquipmentService.luau      # RPG gear inventory, equipping, modifiers
│   │       ├── StatResolver.luau          # Centralized stat calculation engine
│   │       ├── SkillService.luau          # Active skill slots & cooldown engine
│   │       ├── PassiveService.luau        # Passive skill tree unlocks & modifiers
│   │       ├── TargetResolver.luau        # Authoritative target validation
│   │       ├── ModifierResolver.luau      # Deterministic modifier calculations
│   │       ├── DamagePipeline.luau        # Multi-phase damage, shields, downed
│   │       ├── StatusService.luau         # Poison, Ignite, Chill, Freeze, Bleed
│   │       ├── EffectResolver.luau        # Data-driven generic effect dispatcher
│   │       ├── ArenaVisualizer.luau       # Reactive 3D enemy models & health bars
│   │       ├── WorldRoomService.luau      # 3D physical room streaming & geometry lifecycle
│   │       ├── EventService.luau          # 3D co-op puzzle & riddle encounter engine
│   │       ├── ReactionService.luau       # Authoritative 3D attack reaction window engine
│   │       ├── EnvironmentService.luau    # Elemental affinities & battlefield transformations
│   │       └── TestRunner.luau            # 76 end-to-end integration test suites
│   │
│   └── client/                   # StarterPlayerScripts.Client
│       ├── init.client.luau            # Client bootstrap
│       ├── UIController.client.luau    # Master HUD, Map visualizer, card hand, reaction prompt
│       ├── ClassSelectUI.client.luau   # Lobby class & subclass picker UI
│       ├── RelicUI.client.luau         # HUD horizontal relic bar & tooltips
│       └── CombatVFXController.client.luau # Client 3D attack motions, projectiles, and AoE
│
└── tests/
    └── verify_phase1_integration.py    # 1,429 offline architecture & logic verifiers
```

---

## 🚀 Building & Running Locally

### Prerequisites
* [Rojo CLI](https://rojo.space/) (v7.4.0+)
* [Python](https://www.python.org/) 3.9+ (for offline verification)
* [Roblox Studio](https://www.roblox.com/create)

### 1. Run Offline Logic & Architecture Verifiers
```bash
python tests/verify_phase1_integration.py
```
*Executes all 1,429 verifier checks against file schemas, network contracts, typing, and logic rules.*

### 2. Build Roblox Place File
```bash
rojo build -o build.rbxl
```
*Compiles all Luau scripts and assets into a testable Roblox place file with zero errors.*

### 3. Sync into Roblox Studio (Live Development)
```bash
rojo serve
```
*Connect via the Rojo plugin in Roblox Studio and press F5 to Playtest.*

### 4. Interactive Studio Testing (Chat Commands)
In Studio Play Solo, trigger live 3D reaction attacks via chat:
* `/SlowHeavy` — Slow heavy cleave (windup, lunge, recovery).
* `/FastDagger` — Fast dagger thrust.
* `/JumpAttack` — Parabolic leap and ground slam.
* `/ProjectileBolt` — Void orb traveling at 30 studs/s.
* `/UnreactableExplosion` — Expanding AoE telegraph circle.

---

## 📜 License
MIT License. Built for the open-source Roblox development community.
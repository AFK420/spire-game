# Card Rift: Co-op Dungeon ⚔️🃏

A modern **Multiplayer Co-op Roguelike Deckbuilder RPG** built for **Roblox** using [Rojo](https://rojo.space/) and strict Luau (`--!strict`).

Up to 4 players form an adventuring party, choose from 10 distinct RPG Hero classes and 20 specialized subclasses, scale a 4-Act procedural Spire, construct custom decks, collect game-altering relics, and battle synchronized 3D raid bosses in real time.

---

## 🌟 Key Features & Systems

### 1. 10 Core Classes & 20 Subclasses
Every class features unique base stats, starting decks, and active/passive combat gimmicks:
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

---

### 2. Procedural 4-Act Dungeon Tree (`DungeonMap.luau`)
* **4 Distinct Acts**:
  * Act 1: *The Ashen Threshold* (Boss: The Spire Guardian)
  * Act 2: *The Sunken Catacombs* (Boss: The Sunken Matron)
  * Act 3: *The Obsidian Spire* (Boss: The Corrupt Archon)
  * Act 4: *The Heart Summit* (Boss: The Heart of the Rift)
* **10 Tiers per Act**: Normal Combat, Elite Monsters, Campfire Rests, Merchant Shops, and Act Bosses.
* **Reachable Pathfinding**: Validates path connectivity so players can vote on paths after clearing each room.

---

### 3. Multi-Player Co-op Scaling & Sessions (`SessionManager.server.luau`)
* **Dynamic Scaling Formula**:
  $$\text{ScaledHP} = \text{BaseHP} \times (1 + 0.65 \times (\text{PlayerCount} - 1))$$
* **Simultaneous Turn-Phase System**: 45-second turn countdown timer with synchronized ready voting.
* **Downed & Revive State**: Defeated heroes enter a downed state. Teammates can spend 2 Energy or play recovery cards (`First Aid`) to revive them before team wipe.

---

### 4. Modular Relic System (`RelicData.luau`, `RelicManager.server.luau`, `RelicUI.client.luau`)
* **18 Unique Relics** across 5 rarity tiers (`Starter`, `Common`, `Uncommon`, `Rare`, `Boss`).
* **Event-Driven Triggers**: `OnCombatStart`, `OnTurnStart`, `OnCardPlay`, `OnTurnEnd`, `OnDamageTaken`, `OnKill`.
* **Client HUD**: Horizontal scrolling relic bar with animated hover tooltips and trigger pulse bounce tweens.

---

### 5. Persistent Meta-Progression (`ProfileStore.server.luau`)
* Uses Roblox `DataStoreService` with retries, exponential backoff, autosaving, and Studio safety.
* Tracks permanent currency (**Aether Shards**), unlocked class IDs, and lifetime run victories.

---

### 6. Client Interface (`UIController.client.luau`, `ClassSelectUI.client.luau`)
* **Lobby Class Selector**: Interactive modal displaying all 10 classes, stat cards, gimmick summaries, and subclass toggle switches.
* **Dungeon Map Visualizer**: 10-tier interactive map tree with golden pulsing available nodes.
* **Combat HUD**: Interactive card hand with elevation tweens, energy counters, HP/Shield bars, floating combat numbers, and Boss intent overhead displays.
* **Card Drafting Modal**: Post-combat victory screen offering 3 draftable cards to add to the deck.

---

## 📁 Repository Structure

```text
spire-game/
├── default.project.json          # Rojo project mapping configuration
├── README.md
├── src/
│   ├── shared/                   # ReplicatedStorage.Shared
│   │   ├── CardData.luau         # Core card library & 20 class signature cards
│   │   ├── ClassData.luau        # 10 classes, 20 subclasses, starting decks
│   │   ├── DungeonMap.luau       # 4-Act, 10-Tier procedural tree generator
│   │   └── RelicData.luau        # 18 unique relics, rarities, triggers
│   │
│   ├── server/                   # ServerScriptService.Server
│   │   ├── ClassManager.server.luau    # Class profiles, decks, gimmick dispatcher
│   │   ├── CombatServer.server.luau    # 3D arena spawner, boss AI, damage resolution
│   │   ├── GameCoordinator.server.luau # Master run state machine & rewards
│   │   ├── ProfileStore.server.luau    # DataStore persistence for Aether Shards
│   │   ├── RelicManager.server.luau    # Relic inventory & passive trigger engine
│   │   ├── SessionManager.server.luau  # Co-op scaling, 45s timer, revive system
│   │   └── init.server.luau            # Server bootstrap
│   │
│   └── client/                   # StarterPlayerScripts.Client
│       ├── ClassSelectUI.client.luau   # Lobby class & subclass picker UI
│       ├── RelicUI.client.luau         # HUD horizontal relic bar & tooltips
│       ├── UIController.client.luau    # Master HUD, Map visualizer, card hand
│       └── init.client.luau            # Client bootstrap
```

---

## 🚀 Building & Running Locally

### Prerequisites
* [Rojo CLI](https://rojo.space/) (v7.4.0+)
* [Roblox Studio](https://www.roblox.com/create)

### Steps
1. **Clone the repository**:
   ```bash
   git clone https://github.com/AFK420/spire-game.git
   cd spire-game
   ```

2. **Start the Rojo sync server**:
   ```bash
   rojo serve
   ```

3. **Open Roblox Studio**:
   * Open a blank baseplate or create `spire-game.rbxlx`:
     ```bash
     rojo build -o spire-game.rbxlx
     ```
   * Open `spire-game.rbxlx` in Roblox Studio.
   * Click **Connect** on the Rojo Studio Plugin.
   * Press **F5** to Playtest!

---

## 📜 License
MIT License. Built for the open-source Roblox development community.
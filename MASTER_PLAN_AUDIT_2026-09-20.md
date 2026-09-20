# Card Rift Master Plan Audit — 2026-09-20

## Scope and evidence

Reviewed:

- the shared ChatGPT conversation titled `Review Game Plan`;
- `CARD_RIFT_MASTER_PLAN_REVISED.md` (2,696 lines);
- all repository source and test files (50 files / 31,439 lines after this milestone);
- architecture, schema, phase, network, persistence, deck, and risk documentation;
- Git revision `c082116da0c293acc1d24ec89b783b9d73b99696` and the current Phase 5 working tree.

Automated evidence:

- 1,767 offline checks passed;
- all 52 Luau files compiled;
- all Luau files retain `--!strict`;
- zero `_G` references;
- zero merge-conflict markers;
- zero whitespace errors from `git diff --check`.

The offline verifier is source-oriented. It does not prove that Roblox Studio, networking, rendering, DataStore access, device input, or live multiplayer behavior succeeds.

## Executive verdict

The plan's product direction is good. The repository is architecture-heavy and content-light, exactly as the shared chat concluded. The correct next objective remains one replayable Act 1 vertical slice.

The project is not production-ready. It is a strong prototype/framework with meaningful gameplay systems, but it lacks the content volume, runtime evidence, presentation quality, operational tooling, accessibility, analytics, and platform validation required for release.

## “Done” claims checked against code

| Plan area | Verdict | Evidence / qualification |
| --- | --- | --- |
| Authoritative run/player/combat state | Implemented | Central ownership exists in `RunManager` and `CombatService`. Current architecture supports one active run/combat per server process. |
| Stable card instances | Implemented | Server-generated runtime IDs and pile invariants exist. |
| Centralized networking and rate limits | Implemented | Remote creation/validation is centralized in `NetworkService`. |
| Transactional card/skill actions | Implemented | `ActionTransaction` snapshots party, enemies, statuses, relic state, logs, and buffered events. |
| Target/Modifier/Damage/Effect resolvers | Implemented | Separate services exist and are exercised by source and in-game test definitions. |
| Persistent profiles/collection/decks | Implemented foundation | Versioned profiles, fail-closed loading, UpdateAsync, collection ownership, deck CRUD, slots, and active deck exist. Production DataStore load testing is still required. |
| Deck Builder UI | Implemented prototype | Core three-column operations exist. Final art, responsive layout, controller/touch polish, accessibility, and usability testing are missing. |
| Procedural 4-act map | Implemented structurally | The graph and act scaffolding exist. Acts 2–4 are not content-complete experiences. |
| 3D rooms/events/campfire/merchant | Implemented prototype | Room lifecycle exists. Only two event definitions and a very small merchant pool exist. Merchant normal offers are now personal. |
| Reaction V2 | Implemented foundation | Authoritative Dodge/Parry timing and four presentation types exist. Final animations, audio, silhouettes, accessibility, latency tests, and live boss validation remain. |
| Equipment/skills/passives | Implemented foundation | Services and schemas exist; content is far below final scope (3 equipment definitions, 5 skills, 10 passive nodes across the data set). |
| Statuses | Partial | Poison, Ignite, Shock, and Bleed have behavior. Chill and Freeze remain deliberately unimplemented/fail-closed. |
| Classes | Partial | Ten class definitions and twenty subclasses exist, but definition count is not equivalent to complete class gameplay. Several advanced gimmicks remain roadmap-only. |
| Verification | Partial | 1,767 offline checks pass and 85 in-game suites are defined. This audit did not execute Roblox Studio suites. |
| Break/Stagger | Implemented foundation in this milestone | Elite/boss meters, Heavy and Parry contributions, action cancellation, direct-damage vulnerability, HUD, and Suite 77 are present. |
| Act 1 enemy data | Implemented foundation in this milestone | Nine definitions, deterministic move cycles, tier compositions, target modes, reaction profiles, readable intent names, and Suite 78 are present. Final presentation and tuning remain. |
| Soul Eater | Implemented mechanic in this milestone | Devour the Fallen reacts once per allied defeat across all current kill paths, gains Attack, refreshes attack intents, supports rollback, and is covered by Suite 79. |
| Storm Mage | Implemented prototype in this milestone | Static Lightning Field uses a replicated floor telegraph and server-authoritative X/Z position checks. Failures take damage and two Shock stacks; Shock amplifies direct damage and expires. Suite 80 covers the deterministic rules. Studio feel/network validation remains required. |
| Card interaction | Fixed and hardened in this milestone | The HUD replaces defeated implicit targets, uses deterministic living-target fallback, exposes a topmost cross-input activation surface, and displays pending/success/rejection feedback. The server's effect result is now a pure numeric array, preventing the observed post-click exception that blocked damage, card consumption, and snapshot delivery. PlayCard also fails visibly and resynchronizes on unexpected handler errors. Live device validation remains required. |
| Enemy interrupts | Implemented foundation in this milestone | Shield Priest Aegis Transfer and Bomb Carrier Detonate carry explicit Break-interrupt metadata, receive a 20-point normal-enemy interrupt meter, announce exact cancellation, and expose unmistakable HUD guidance. Suite 81 covers staged progress, cancellation, and recovery. |
| Intent readability | Implemented foundation in this milestone | Single-target intents lock and replicate the player they will actually attack. The HUD names exact targets and explicitly labels Dodge+Parry, Dodge-only, Parry-only, movement, preparation, and non-reactable defense checks. Suite 82 covers cross-snapshot stability and guidance modes. |
| Spire Guardian | Implemented foundation in this milestone | Three named phases transition at guarded 70%/35% HP thresholds, grant one-time barriers, rotate distinct reactions, and culminate in a party Break check. Suite 83 covers threshold, barrier, cycle, interrupt, and defeat invariants. Studio presentation and balance validation remain. |
| Combat feedback | Implemented foundation in this milestone | Authoritative combat events now drive target-attached numbers, impact flashes, and local capped camera response. Stable target IDs, reduced-motion opt-out, popup limits, duplicate suppression, and Suite 84 are present. Studio tuning and audio remain. |
| Flexible builds and card limits | Implemented foundation in this milestone | Cards/skills are class-agnostic; rarity/card copy caps and battle/run use limits are authoritative, visible, and rollback-safe. Each card owns Accuracy and presentation metadata. Suite 85 covers the rule layer. |
| Enemy defenses | Implemented foundation in this milestone | Act 1 enemies expose Armor/Evasion, Accuracy can miss, physical Armor has Arcane/Piercing counterplay, and three enemies rotate data-driven defensive stances. Balance and live readability testing remain. |

## Current content inventory

- 25 card definitions;
- 10 class definitions and 20 subclass definitions;
- 5 active skills;
- 10 passive nodes total;
- 3 equipment definitions;
- 18 relics;
- 2 event definitions;
- 9 enemy definitions selected through `EnemyData`: Spire Sentinel, Dark Cultist, Shield Priest, Bomb Carrier, Soul Eater, Storm Mage, Gremlin Nob, Iron Bulwark, and Spire Guardian.

This is enough to exercise architecture, not enough to sustain the promised game.

## Master-plan edits still needed

### Resolve the card-acquisition contradiction

Section 7 describes a future gacha/banner system as planned, while Section 38 recommends no paid random combat-card gacha. The authoritative direction should be:

- no paid random combat-card acquisition;
- gameplay-earned acquisition may use packs/banners only with transparent odds, pity, crafting, and duplicate protection;
- premium spending remains cosmetic/identity/convenience only;
- policy requirements must be rechecked at implementation time.

Rename Section 7 to `Deferred Gameplay-Earned Card Acquisition` so it cannot be mistaken for an approved monetization plan.

### Distinguish architecture from playable completion

Phrases such as “10 classes,” “4 acts,” or “status system” should carry one of three labels:

- `Definition exists`;
- `Runtime foundation exists`;
- `Content complete and playtested`.

Most large systems are in the first two categories, not the third.

### Make acceptance criteria executable

Every future milestone should include:

- exact player-visible behavior;
- authoritative owner;
- failure/rollback rules;
- network DTO changes;
- Studio integration tests;
- interactive multiplayer scenarios;
- performance and device checks;
- an explicit list of systems not being redesigned.

### Replace scale targets with proof targets

Do not use “40–80 passive nodes,” “10 classes,” or “4 Acts” as near-term success metrics. First prove:

- three distinct Warlord builds;
- one contrasting Aether Mage co-op interaction set;
- five mechanics-first normal enemies;
- two or three elites;
- one multi-phase boss;
- one complete 10–15 minute run that players immediately replay.

## Production blockers by severity

### P0 — blocks meaningful external playtest

- all five recommended normal-enemy identities now have their foundation mechanic; tuning, VFX, animation, audio, and four-client presentation validation remain;
- the Spire Guardian's multi-phase rules are implemented, but its final model, animation, VFX, audio, balance, and four-client encounter validation are missing;
- no Studio execution record for the current build;
- placeholder/blockout visuals and missing production audio/animation;
- incomplete Chill/Freeze and limited visible synergy language;
- no first-run onboarding.

### P1 — blocks safe release

- one-active-run/one-active-combat server assumption;
- no repository-managed CI/toolchain pinning;
- no automated Roblox Studio runner in the repository;
- no analytics/telemetry plan for balance and funnel decisions;
- no accessibility, localization, console/mobile input, or low-end performance pass;
- no production persistence load/rollback/migration rehearsal;
- no operational moderation/reporting/recovery plan.

### P2 — expansion work, not current blockers

- all remaining classes and Acts 2–4;
- large passive trees;
- affix/crafting economy;
- cross-session run resume;
- cosmetic store/season pass;
- endgame, raids, guilds, trading, leaderboards, and seasons.

## Recommended next implementation

Validate the new vertical-slice mechanics and then deepen the first playable build before adding more infrastructure:

1. execute all 85 suites in Studio, including use-limit resets, miss feedback, Armor/Piercing, defensive stances, combat-feedback targeting, Spire Guardian thresholds, Storm Mage geometry, and exact targets;
2. run four-client latency, movement readability, boss-coordination, and encounter-pacing playtests;
3. tune the implemented numbers/flashes/camera response, add animation-aware hit-stop and layered audio, then begin the Warlord card/build vertical slice.

## Bottom line

The architecture should be preserved. The next work should be player-visible combat/content work. “Production-ready” must remain false until the Studio acceptance pass and P0/P1 blockers are closed.

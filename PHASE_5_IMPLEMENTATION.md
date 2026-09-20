# Phase 5 — Replayable Act 1 Vertical Slice

## Objective

Make one Act 1 run genuinely fun to replay before expanding to ten complete classes, four content-complete acts, large passive trees, crafting, banners, or monetization.

This phase preserves the existing server-authoritative architecture and moves development toward combat feel, mechanics-first content, readable co-op interactions, and short iteration loops.

## Audit baseline

- Audited source revision: `c082116da0c293acc1d24ec89b783b9d73b99696` plus the Phase 5 working-tree changes documented here.
- Build fingerprint: `phase5_flexible_builds_20260920`.
- Source: 52 strict Luau files.
- Offline verification: 1,767 checks passing, including compilation of every Luau file.
- In-game verification source: 85 suites are defined; Suites 77–85 cover Break/Stagger, authored Act 1 enemies, Soul Eater escalation, Storm Mage Shock/movement geometry, Break-driven interrupts, exact intent guidance, Spire Guardian phases, positional feedback, flexible builds, card limits, Accuracy, Armor, and Evasion. These suites still require execution in Roblox Studio.
- Interactive verification still required: 3D timing, input feel, UI readability, animation, VFX, audio, multiplayer pacing, and device performance.

## Implemented in this milestone

### 1. Server-authoritative Break/Stagger foundation

`BreakService.luau` now owns deterministic Break state transitions.

- Normal enemies remain non-breakable by default.
- Elites receive a configurable 60-point meter.
- Act bosses receive a configurable 100-point meter.
- Heavy cards add 20 Break.
- successful Parry adds 15 Break.
- Perfect Parry adds 30 Break.
- Break values clamp at the threshold and cannot be farmed while the enemy is already Broken.
- A card-caused Break cancels exactly one upcoming enemy action.
- A Parry-caused Break counts the parried action as the cancelled action.
- Broken enemies take 25% increased direct damage.
- Periodic damage is deliberately excluded from the vulnerability multiplier.
- The meter resets only when the Broken window ends.

All values live in `GameConfig.Break` so playtests can tune the system without editing the state machine.

### 2. First-class card tags

Card definitions and client views now support `Tags`.

- `Strike`: `Attack`
- `Heavy Blow`: `Attack`, `Heavy`
- `Poison Dart`: `Attack`, `Poison`

The combat hand renders tags so mechanical identity is visible instead of hidden in descriptions. Future class, passive, relic, equipment, and status rules should query tags rather than branch on card names.

### 3. Break HUD

Elite and boss enemy panels now show:

- current Break value;
- Break threshold;
- explicit `BROKEN` state;
- the direct-damage bonus during the window.

The meter is absent for normal enemies to avoid unnecessary UI noise.

### 4. Personal merchant offers

Normal merchant stock is now personal rather than shared.

- Offers are deterministic for `(run seed, act, tier, node, user ID)`.
- Each party member receives a distinct mutable ware table.
- Run snapshots expose only the requesting player's offers.
- Purchase locks are keyed by `runId:userId:itemId`.
- One player's purchase cannot mark another player's normal offer as purchased.
- Existing fail-closed card-grant ordering is preserved.

Rare party-limited objects can be added later as an explicit item type; normal cards and equipment must remain personal by default.

### 5. Data-driven Act 1 enemy foundation

`EnemyData.luau` now owns nine enemy identities, combat roles, base scaling, deterministic move cycles, reaction profile IDs, target modes, and tier compositions.

- Normal encounters progress from a baseline Sentinel into protector, countdown, escalation, and reaction-control compositions.
- Early and late elite tiers select Gremlin Nob and Iron Bulwark respectively.
- The Spire Guardian has an authored boss cycle rather than a random intent roll.
- Shield Priest can shield the living ally with the lowest HP ratio.
- Party-wide attacks author their target mode explicitly.
- Combat snapshots show authored move descriptions and values.
- `CombatService` no longer selects attack profiles with enemy-name conditionals.
- Suite 78 validates the registry, compositions, target metadata, damage scaling, and move-cycle wrapping.

### 6. Soul Eater — Devour the Fallen

`EnemyMechanicsService.luau` now owns defeat-triggered enemy reactions.

- Every living Soul Eater gains 3 Attack when another enemy dies.
- Card, skill, status, class-gimmick, Parry-counter, and Thorns defeats all use the same authoritative mechanic.
- A per-enemy `DefeatProcessed` marker prevents duplicate triggers.
- The marker and Attack mutation live in `EnemyState`, so failed card or skill transactions roll them back automatically.
- Multiple Soul Eaters react in stable instance-ID order.
- If Soul Eater is currently telegraphing an attack, the intent value is recalculated immediately so the HUD never displays stale damage.
- Fixed-value Buff/Defend moves retain their authored value.
- Suite 79 covers living checks, duplicate suppression, telegraph updates, multiple reactors, and self-defeat exclusion.

### 7. Storm Mage — Static Lightning Field and Shock

Storm Mage now proves a hybrid combat rule: most attacks remain timing reactions, while explicitly authored floor hazards require physical movement.

- `Static Lightning Field` snapshots a player position and marks a seven-stud red/purple floor circle for the whole party.
- Players escape by walking outside the circle before impact; C/V do not avoid this attack.
- `SpatialHazardService` checks each player's authoritative `HumanoidRootPart` X/Z distance at impact, so jumping cannot bypass the floor rule.
- The exact boundary is safe. Missing character/root data fails closed instead of granting an unverified escape.
- A player still inside takes the authored lightning hit and receives two Shock stacks.
- Each Shock stack increases incoming direct damage by 5%, up to 20 stacks/+100%; periodic damage is excluded.
- Shock has a three-turn duration and decays without dealing damage itself.
- Reaction-window DTOs carry explicit `AvoidanceMode`, hazard radius, and world position so UI and VFX do not infer gameplay rules.
- Suite 80 covers authored intent data, metadata propagation, geometry, fail-closed validation, direct/periodic damage behavior, stack cap, and expiry.

### 8. Card interaction reliability

The combat hand now uses a topmost `Activated` input surface across mouse, touch, and gamepad. Before sending an attack card, the client reconciles its target against the latest enemy snapshot, rejects zero-living-target cases locally, and deterministically replaces missing or defeated selections. Clicks show immediate pending feedback, followed by the server's explicit success or rejection message.

The server-side resolver now returns a pure numeric effect-result array and exposes aggregate success through a separate summary function. This prevents generic result iteration from visiting boolean metadata and crashing after a card is removed from the hand but before the action transaction is committed. Combat iteration uses `ipairs`, unexpected PlayCard handler errors produce an explicit rejection plus a fresh snapshot, and enemy-turn party lookup uses the combat service's authoritative party reference.

### 9. Break-driven normal-enemy interrupts

Shield Priest and Bomb Carrier now opt into an explicit 20-point interrupt meter without making every normal enemy breakable.

- `Aegis Transfer` displays `BREAK TO CANCEL THE SHIELD` and is cancelled when Broken before resolution.
- `Detonate` displays `BREAK TO CANCEL DETONATION` and is cancelled when Broken before impact.
- Their ordinary setup/attack moves are explicitly non-interruptible.
- Heavy-card Break progress made during a non-interruptible move is preserved at 19/20 instead of wasting the setup or cancelling the wrong move.
- The exact cancelled move is written to the combat log and announced to the party.
- Suite 81 validates metadata, staged progress, cancellation, recovery, and the one-Heavy Aegis interruption path.

### 10. Exact intent targets and reaction guidance

Enemy intent panels now answer both questions a player needs before committing cards: “Who will be hit?” and “What response works?”

- Random-player attacks choose and store a living target when the intent is generated.
- Resolution consumes that stored target instead of rolling a different player after the planning phase.
- Every client receives the same target user ID and player-facing target name.
- Party-wide, self, and lowest-HP-ally intents use explicit target language.
- Reaction instructions distinguish `C: DODGE + V: PARRY`, Dodge-only, Parry-only, physical movement, card-phase preparation, and `CANNOT DODGE OR PARRY` defense checks.
- The local player's targeted intent is highlighted red.
- Suite 82 covers stable replicated targets plus all primary reaction-guidance modes.

### 11. Spire Guardian multi-phase encounter

`BossMechanicsService.luau` now owns a deterministic, server-authoritative Act 1 boss state machine.

- Phase 1, `The Warden`, establishes the baseline Guardian cycle.
- At 70% HP, the boss advances to `Fractured Sentinel`, gains 20 Shield, and rotates through Dodge-only, Parry-only, and non-reactable defense pressure.
- At 35% HP, it advances to `Core Unbound`, gains 30 Shield, and opens with `Core Overload`, an explicit party Break-to-interrupt check.
- `DamagePipeline` clamps HP loss at each pending threshold, so a huge hit or periodic damage cannot skip a phase or kill the boss before its authored mechanics occur.
- Each transition barrier is granted once, the move cycle resets to its authored opener, and a transition triggered during enemy resolution cancels that old-phase action to provide a clear preparation window.
- Card, skill, status, class-gimmick, reaction-counter, and Thorns damage all synchronize through the same phase authority.
- Combat snapshots expose the current phase number and name, and the enemy panel displays both.
- Suite 83 covers thresholds, cycles, one-time barriers, HP gates, the final-phase Break check, and defeat safety.

### 12. World-space combat feedback foundation

`CombatFeedbackData.luau` now defines one shared presentation policy for authoritative combat events, while `CombatVFXController.client.luau` owns their positional rendering.

- Damage, healing, Shield, Break, and phase callouts rise above the actual enemy or player target instead of stacking at screen center.
- Enemy and player target resolution uses stable enemy instance IDs and player user IDs, with a compatibility fallback for older name-addressed events.
- Damage and Break create a short `Highlight` impact flash without changing authoritative state or server timing.
- Camera response is local-only, strength-capped, brief, and stronger for the damaged player than for the attacking player.
- Setting the local player's `ReduceMotion` attribute to `true` disables camera movement.
- Concurrent world popups are capped to avoid four-player burst spam, and the legacy HUD suppresses duplicate central values.
- Suite 84 verifies feedback policy, motion limits, display text, and safe unknown-event fallback.

### 13. Flexible builds, limited cards, and reactive enemy defenses

Cards and active skills now belong to one shared build pool. Hero class choice provides stats and mechanics but never blocks a card, deck, or owned active skill.

- New and migrated saved decks normalize to `ClassId = nil`; the emergency starter deck is also universal.
- Each card owns a five-tier rarity, Accuracy, deck-copy cap, and animation/projectile identity.
- Powerful cards can declare a definition-level `Battle` or `Run` use limit. Counters are server-authoritative, transactional, and visible on the card.
- Common cards may use up to three copies, Rare cards default to two, and Super Rare/Ultra Rare cards default to one; stricter card-specific limits win.
- Enemy-targeting cards and active skills roll Accuracy against visible enemy Evasion. A miss still spends the card/skill resources and cooldown, while valid self-side effects on mixed cards still resolve.
- Enemies own visible Armor. Direct physical damage is mitigated by a capped curve; Arcane, periodic, and `Piercing` damage bypass physical Armor.
- Spire Sentinel, Storm Mage, and Iron Bulwark alternate authored Armor/Evasion stances after specific moves, creating windows for accurate, Piercing, Arcane, or high-risk attacks.
- Every card publishes a melee, projectile, aura, or summon presentation. The client renders card-specific colors/shapes and scales the effect by rarity.
- Suite 85 covers flexible pools, battle/run resets, misses, Armor, Piercing, rarity limits, and defensive stance cycles.

## Non-negotiable invariants

- The server owns combat, targets, resource costs, Break state, damage multipliers, shop inventory, and purchase state.
- Clients receive serializable views and never submit damage, Break values, prices, ownership, or purchase status.
- Card actions remain transactional. Heavy-card Break mutations roll back with HP, Energy, piles, statuses, and events if any required effect fails.
- Definition data and runtime instances remain separate.
- Stable card instance IDs remain authoritative; hand indexes are presentation-only.
- New mechanics must be data-driven and may not add card-name branching to combat services.
- Paid currency may not buy combat power.

## Required Studio acceptance pass

This milestone is not production-approved until all of the following are run in Roblox Studio:

1. Execute all 85 integration suites with zero failures.
2. Enter an elite room and verify a visible 60-point Break meter.
3. Enter an Act Boss room and verify a visible 100-point Break meter.
4. Play five Heavy Blows across the party and verify one Break, one skipped action, one Broken damage window, and clean recovery.
5. Trigger a Good Parry and a Perfect Parry and verify 15/30 Break respectively.
6. Verify a Parry-caused Break does not skip an additional unintended action.
7. Verify direct damage receives the 25% bonus while Poison/Ignite/Bleed ticks do not.
8. Verify Break state remains synchronized for all four clients under latency simulation.
9. Open one merchant with two clients and verify each client sees only personal offers.
10. Buy the same slot on both clients and verify independent costs, cards, gold, and purchased states.
11. Test rapid double-clicks and simultaneous purchases; each player must receive at most one copy from a ware.
12. Test keyboard, gamepad, touch, and low-resolution layouts for the expanded enemy panel.
13. Verify tiers 1, 3, 5, 7, and 8 spawn the authored normal compositions in Studio.
14. Verify Shield Priest protects the most wounded living enemy and Bomb Carrier's third action targets every living player.
15. Verify intent move names, values, and reaction telegraphs remain synchronized across four clients.
16. Kill Cultist beside Soul Eater using a card, status tick, skill, Parry counter, and Thorns; verify exactly one +3 Attack trigger for each death source.
17. Trigger Static Lightning Field with one and four clients; verify the circle is centered consistently and every client sees the same impact timing.
18. Walk one player outside while leaving another inside; verify only the inside player takes damage and receives two Shock stacks.
19. Verify C/V cannot avoid Static Lightning Field, jumping inside does not evade it, and standing exactly at the seven-stud boundary is safe.
20. Verify the HUD shows Shock stacks and the correct direct-damage increase, then verify the stacks expire after three TurnStart ticks.
21. Break Shield Priest during Aegis Transfer; verify the shield is not granted, the exact move is announced as cancelled, and the next move is Censure.
22. Build Bomb Carrier Break during its fuse, finish the meter during Detonate, and verify no party member takes explosion damage.
23. With four clients, verify every single-target intent names the same player on every screen and the eventual reaction window attacks that named player; verify Dodge-only, Parry-only, movement, and non-reactable labels match their actual mechanics.
24. Deal an oversized hit in each Spire Guardian phase and verify HP stops at 70% and 35%, the correct named phase begins, and each transition Shield is granted exactly once.
25. Trigger a phase transition from a card, skill, status tick, reaction counter, Thorns, and end-turn class damage; verify the same phase result is replicated to every client and an old-phase enemy action never resolves afterward.
26. In `Core Unbound`, coordinate Heavy cards/Parries to Break `Core Overload`; verify the move is cancelled once, then verify failure to Break resolves the party-wide hit.
27. With four clients attacking together, verify damage/heal/Shield/Break values attach to the correct targets, never duplicate at screen center, and remain readable under the 12-popup cap.
28. Verify local victim shake is brief and restrained, remote players do not receive victim shake, and setting `ReduceMotion = true` disables camera movement while preserving numbers and flashes.
29. Against Sentinel, Storm Mage, and Iron Bulwark, verify Armor/Evasion values change after their authored stance moves and that card/skill misses match the displayed chance.
30. Verify Battle-limited cards reset next encounter, Run-limited cards remain exhausted between encounters, and neither counter is consumed by a rejected/rolled-back action.
31. Verify Common through Ultra Rare card frames are distinguishable on desktop, controller, touch, and color-limited displays; verify each core card launches its authored melee/projectile/aura/summon presentation.

## Production roadmap from here

### P0 — prove combat feel

- World-space damage numbers, impact flashes, and capped/reduced-motion camera response are implemented; tune them in Studio, then add animation-aware hit-stop and layered audio.
- Exact target and reaction language is implemented; validate truncation, color contrast, and comprehension on low-resolution, touch, and four-client layouts.
- Tune the implemented Storm Mage movement prototype, arena bounds, telegraph contrast, and impact timing through four-client playtests before extending spatial hazards to elites/bosses.
- Shorten normal decision windows through playtest data while keeping instant progression when all living players are ready.
- Add world-space teammate target indicators after the panel language passes readability testing.

Exit criterion: a new player can understand and enjoy a 10–15 minute combat loop without using the deck builder or meta systems.

### P1 — shared build sandbox vertical slice

- 12–18 tested shared-pool cards with visible tags and at least three emergent build packages usable by any class.
- Four cooldown-led, class-agnostic active skills.
- Classes and subclasses must change how a chosen deck plays without owning or restricting that deck.
- 10–15 passive nodes, with major nodes changing rules rather than only percentages.
- A small equipment set with at least three build-defining choices.

Exit criterion: at least three player-created builds can complete Act 1 with meaningfully different decisions, and the same deck behaves differently across at least two classes.

### P2 — Act 1 enemy roster

- The definition and deterministic-cycle foundation for five normal archetypes is present. Shield Priest protection, Bomb Carrier countdown interrupts, Soul Eater escalation, and Storm Mage Shock/movement pressure are implemented; final presentation and tuning remain.
- Two elite definitions are present; add bespoke Break interactions and a third only if playtests reveal a missing role.
- The Spire Guardian's three-phase server-authoritative foundation is implemented with preparation, Dodge-only, Parry-only, non-reactable, HP-gated, and party Break mechanics. Complete its models, animation, VFX, audio, balance, and four-client validation.

Recommended first normal roster:

- Spire Sentinel: readable baseline attacker.
- Shield Priest: protects a priority target and can be interrupted.
- Bomb Carrier: visible three-turn countdown.
- Soul Eater: gains power when another enemy dies.
- Storm Mage: changes safe reaction zones and applies Shock-related pressure.

### P3 — status and co-op interactions

- Finish Chill and Freeze runtime behavior; tune the implemented Shock stack values and duration through playtests.
- Implement visible Wet + Lightning, Freeze + Heavy, Bleed + Heavy, and Poison + Fire interactions.
- Add combat-log and VFX language that identifies which teammate created and consumed a setup.
- Keep interactions transactional and data-driven.

### P4 — surrounding run loop

- Personal combat reward choices.
- Small personal equipment reward loop.
- Improved campfire choices.
- Three or four polished events.
- End-of-run summary that explains the build and rewards.
- First-run tutorial with staged disclosure.

### P5 — contrasting co-op class

Add Aether Mage only after the Warlord/Act 1 loop is stable. Use it to prove cross-player setup and payoff, not merely a second damage rotation.

### Deferred until the vertical slice is proven

- 40–80 passive nodes per class;
- all ten complete classes;
- Acts 2–4 content production;
- full affix/crafting economy;
- cross-session run resume;
- card acquisition banners;
- monetization implementation;
- endgame, seasons, raids, guilds, trading, and leaderboards.

## Known production blockers

- The combat engine currently supports one active encounter per Roblox server process. Multiple independent parties in the same server need a keyed combat/run architecture or an explicit one-party-per-server product decision.
- Enemy definitions, move selection, five normal Act 1 mechanics, and Spire Guardian phase transitions are implemented as foundations; final balance, presentation, and four-client Studio validation remain.
- `UIController.client.luau` is a large monolith and will become increasingly expensive to test as combat, map, reward, and inventory polish expands.
- There is no repository-managed CI/toolchain configuration for Rojo, Luau analysis, formatting, and automated Studio execution.
- The repository does not contain production art, animation, audio, final enemy models, accessibility settings, localization, analytics, moderation/reporting flows, or performance budgets.
- Static compilation does not replace Roblox Studio runtime execution or four-client network testing.

The project is therefore architecture-strong and newly moving in the correct vertical-slice direction, but it is not yet production-ready or content-complete.

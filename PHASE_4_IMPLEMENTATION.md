# PHASE 4 — PERSISTENT ACCOUNT, CARD COLLECTION & DECK BUILDER FOUNDATION

## Card Rift: Co-op Dungeon

This document describes the architecture, data models, state boundaries, network contracts, and verification results for **Phase 4: Persistent Account, Card Collection & Deck Builder Foundation**.

---

## 1. Executive Summary & Goals

Phase 4 establishes the persistent meta-progression, card collection management, and deck building architecture for Card Rift: Co-op Dungeon while leaving the run-scoped combat runtime intact:

1. **Persistent Account Profile**: Upgraded `PersistenceService` to schema `ProfileVersion = 1` with a deterministic migration and reconcile pipeline.
2. **Permanent Card Collection**: Implemented `CardCollectionService` to manage permanent definition ownership and copy counts, supporting future gacha/banner card grants cleanly.
3. **Persistent Deck Management**: Implemented `DeckService` with server-generated GUIDs, configurable slot entitlements (`BaseDeckSlots = 4`), and authoritative validation (collection ownership, copy limits, min 8 / max 30 size).
4. **Active Deck Run Integration**: Connected `ClassService.initializeStartingDeck` to synthesize fresh runtime `CardInstance`s from the player's selected `SavedDeck`. In-run card movement never mutates persistent decks or collections.
5. **Deck Builder Network Contracts**: Added 11 RemoteEvents in `NetworkService` with token-bucket rate limiting and zero client-minting pathways.
6. **Comprehensive Verification**: Implemented 6 new test suites (Suites 53–58) covering all migration, collection, deck, run integration, and network security assertions.

---

## 2. Core State Invariants

- **`Persistent Card Collection`**: Definition ownership and copy counts only (`{ [string]: number }`). Never stores runtime `CardInstance`s.
- **`Saved Deck`**: References `CardDefinition` IDs and quantities. Never stores runtime `CardInstance`s.
- **`Runtime CardInstance`**: Ephemeral object created dynamically for an active dungeon run with unique runtime GUID and owner ID.
- **`RunState`**: Never becomes the persistence authority for permanent collection or deck ownership.
- **`DeckSlotEntitlement`**: Determines how many saved decks an account may store (`BaseDeckSlots + AdditionalDeckSlots`).
- **`Authority Rule`**: Only authoritative server systems may grant persistent collection items or modify deck entitlements. Clients can never create or insert persistent objects directly.

---

## 3. End-to-End Vertical Slice Proof (Suite 57)

Suite 57 in `TestRunner.luau` verifies the complete Phase 4 lifecycle:

1. **New Account Initialization**: Profile is provisioned with starter collection and a default saved deck.
2. **Custom Deck Creation & Selection**: Player creates a custom deck ("Speed Run Deck") with 8 valid cards, validates it, and sets it as `ActiveDeckId`.
3. **Run Initialization**: `ClassService.initializeStartingDeck` reads the active saved deck and synthesizes 8 runtime `CardInstance`s with unique runtime GUIDs into `PlayerState.Deck`.
4. **Combat Card Movement**: Player draws 4 cards, plays 1 card to `DiscardPile`, exhausts 1 card to `ExhaustPile`.
5. **Immutability Guarantee**: After combat operations, the persistent `SavedDeck` card counts (3 Strikes, 2 Defends, 2 HeavyBlows, 1 RageSlash) and permanent `CardCollection` counts remain 100% unchanged.
6. **Active Run Isolation**: Modifying or saving the persistent deck mid-run does not mutate the active run's in-progress card piles.

---

## 4. Test Suite Summary

The test runner now covers **58 distinct test suites** across all 4 phases:

- **Suite 53**: Phase 4 Profile Architecture & Migration (Default v1 profile, legacy v0 profile migration, malformed profile recovery, currency non-negativity, collection & deck reconciliation).
- **Suite 54**: Phase 4 Card Collection Service (Authoritative card grant, invalid card rejection, fractional quantity rejection, authoritative card deduction, insufficient copies rejection, collection view serialization).
- **Suite 55**: Phase 4 Deck Model, Slot Entitlement & Deck Service (Slot entitlement queries, 4 base slots, slot exhaustion rejection, entitlement expansion, server-generated GUIDs, deck renaming, duplication, deletion).
- **Suite 56**: Phase 4 Deck Validation & Active Deck Selection (Card existence validation, collection ownership checks, copy limits, min/max deck size checks, active deck selection, fallback on deletion).
- **Suite 57**: Phase 4 Run Integration & Complete Vertical Slice (Active saved deck selection, runtime CardInstance synthesis, combat draw/play/discard/exhaust, persistent deck and collection immutability, active run isolation).
- **Suite 58**: Phase 4 Network Security & Remote Contract Hardening (All 11 Phase 4 RemoteEvents, forged DeckId prevention, unowned card injection rejection, over-quantity rejection, rate limiting).

---

## 5. Scope Boundaries & Intentional Deferrals

To maintain architectural focus, the following systems remain intentionally unstarted:
- Full Deck Builder UI with drag-and-drop visuals (deferred to UI polish phase).
- Card artwork, animations, and sound effects.
- Gacha banner summoning logic, pity counters, and pull animations.
- Robux purchases and monetization integrations.
- Hundreds of card definitions (Phase 4 uses the verified starter roster).

# QuestRecall Forever

[![Support on Ko-fi](https://img.shields.io/badge/Support_on_Ko--fi-7139A8?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/aylaforge)

QuestRecall Forever is a quest journal for WoW Forever, maintained by **AylaForge Studios**. It keeps a per-character record of quest activity the addon observes and helps you look up where a quest might start.

## What the addon does

- **Quest history.** Browse observed quest activity with a timeline, search, filters, and recorded evidence. The journal can show observed recovery events. It cannot reconstruct activity from before the addon recorded it.
- **Quest items.** Inspect item quantities, known quest associations, and warnings. The relevance filter changes what the journal displays and leaves the recorded item data intact.
- **Possible quest origins.** Request a lookup for NPCs, world objects, or items that may start a quest. With optional QuestieDB data, the journal shows locations and coordinates when available. A listed origin does not guarantee that the quest can be picked up again.
- **Diagnostics and navigation.** Open the journal with its minimap button or `/qrf diario`. Use the Diagnostics tab to review the available addon state, or enter `/qrf historial` to list the current character's records in chat.

## Version and validation

The local **v1.0.0** milestone was manually validated in the recorded WoW Forever session. Quest history, quest item associations, and the Diagnostics tab were accessible, and no Lua errors were observed during that check. Compatibility across other client builds and complete QuestieDB coverage remain unverified.

This repository provides the source code. The local v1.0.0 milestone is separate from a GitHub release.

## Installation

Copy the `QuestRecallForever` folder into the `Interface/AddOns` directory of your WoW Forever client. QuestieDB is optional and installed separately. The addon journal is available through `/qrf diario` or the minimap button.

## Voluntary support

QuestRecall Forever is free to download and use. [Contributions through Ko-fi](https://ko-fi.com/aylaforge) are entirely optional and support ongoing development.

## License

Copyright © 2026 AylaForge Studios. Released under the [MIT License](LICENSE).

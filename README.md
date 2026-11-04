# Delirium Milk

Build 42 mod for the Delirium server. No dependencies, server-side logic only.

In vanilla B42 milk piles up for years: a cow milked at least every 21 days never dries off, every milking grows her udder to 130% of its maximum (about 40 L a day from a Holstein), a cow left unmilked after that loses health, and fluids never age. This mod changes all of that:

- **Lactation ends.** A cow gives milk for `LactationDays` game days after calving, then dries off until her next calf. Cows already in milk when the mod is added count from that moment.
- **Udder limit.** The udder never grows past `UdderCapPercent` of the cow's genetic maximum. Vanilla only hurts a cow above 115%, so with the cap at or below 115 a cow left unmilked is no longer hurt. Lower values also mean less milk per milking.
- **Milk sours.** Cow, sheep and animal milk in any container (bucket, bottle, barrel, trough, vehicle trunk) turns into **Sour Milk** after `SpoilDays` game days. Sour milk is a mildly poisonous drink, good only for pouring out. A powered fridge or freezer slows it down. Fresh milk poured in thins out the age; milk poured from one container into another keeps its age. Stock already stored when the mod is added counts from that moment.

Milk is checked around online players (`ScanRadius` tiles, their floor and one up and down), a full round every 30 game minutes, plus their own inventories and the trunks of loaded vehicles. Ageing is counted from timestamps, so milk left in an unloaded area sours as soon as someone comes back.

## Sandbox options (page DelMilk)

| Option | Default | Meaning |
|---|---|---|
| `LactationDays` | 300 | game days of milk after calving (0: vanilla, all year) |
| `UdderCapPercent` | 100 | udder limit, percent of the genetic maximum (vanilla grows to 130) |
| `SpoilDays` | 10 | game days before milk turns sour (0: never) |
| `FridgePercent` | 25 | ageing speed in a powered fridge, percent of normal |
| `FreezerPercent` | 5 | ageing speed in a powered freezer, percent of normal |
| `ScanRadius` | 40 | tiles around each online player checked for milk |

The server log says once an hour what it did (`DelMilk: hour: ... cows loaded, ... udders capped, ... dried off; ... containers soured`).

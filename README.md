# SnackBar

A World of Warcraft 1.12 (Turtle / Octo client) addon. One button eats the best food or drink in your bags, plus optional custom bars for potions, bandages and other consumables.

## Install
Copy this folder into `Interface/AddOns/` and make sure it is named `SnackBar`.

## Features
- Auto button picks health/mana food: conjured first, percentage foods before flat ones, never stat-buff food.
- Flyout of the other usable items; left or right click uses them.
- Custom bars (up to 6, saved per character) with ordered item lists, own keybind, own lock timer, own flyout direction.
- Per-bar "don't use in combat" / "don't use out of combat", and "skip items whose buff is already on me".
- Food is sorted into buff / mana / health / health+mana; custom bars can auto-fill from a category (mana classes only get mana food if it gives a buff or is conjured health+mana food).
- Mana classes can choose health or mana food first; the button switches to the other kind while you eat so you can drink at the same time.
- Per-item "use first out of combat" mark (overrides a combat-only bar); bandages are skipped while you have Recently Bandaged.
- Listed items you don't carry still show their (greyed) icon and tooltip; shift-click items or chat links into the add box.
- Optional: with the Nampower client mod, an item's buff is read from game data so the buff check works before first use.
- Greyed while in combat, locked, on cooldown or dead; respects the global cooldown.

## Commands
- `/sb` options, `/sb custom` custom bars, `/sb eat` eat now, `/sb rescan`, `/sb reset` positions.
- Shift+drag any button to move it. Keybinds are under Key Bindings > SNACKBAR.

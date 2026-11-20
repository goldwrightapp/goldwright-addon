# Goldwright changelog

## 0.7.3

Urgent fixes for prices and combat: the Sell tab's prices for items that don't stack, recipe prices in tooltips, copper in item prices, and the keyboard, close button and Escape in combat. Full scans now also update random-suffix gear.

- **Sell tab prices for books, bags, gear and recipes:** the auction house groups identical listings ("31 at 94s 99c"), and Goldwright divided that price by the count, so it showed 3s 6c and suggested selling for 1s. It now reads them the way the auction house means them, so the cheapest listings, the suggested price and My Auctions' undercut check match what you see in the auction house. Tooltips and the website were never affected. ([#5](https://github.com/goldwrightapp/goldwright-addon/issues/5))
- **Keyboard in combat:** opening a profession (or any Goldwright window) for the first time while in combat could leave the keyboard stuck until combat ended. Goldwright windows no longer take the keyboard at all. ([#3](https://github.com/goldwrightapp/goldwright-addon/issues/3))
- **Recipe prices in tooltips:** a recipe's tooltip showed the price of the item it makes. Blueprint: Repair Bot showed about 20s, the Repair Bot's price, when the blueprint sold for 33s and up. Recipes, patterns, plans, schematics, blueprints and the like now show their own price. ([#7](https://github.com/goldwrightapp/goldwright-addon/issues/7))
- **Full scans now update random-suffix gear:** a full scan tells "of the Bear" from "of the Eagle", so after a scan each suffix shows its own cheapest listing, or none listed. Before, suffix gear kept the data pack's older prices after a scan. ([#9](https://github.com/goldwrightapp/goldwright-addon/issues/9))
- **Copper prices for items:** Forever's auction house now takes copper in item prices (gear, books, bags, recipes and the rest), so the Sell tab no longer rounds them down to whole silver. A typed 30s 99c posts at 30s 99c, Sell Fast is 1c under the cheapest listing, and the "Gear posts in whole silver" line is gone. ([#8](https://github.com/goldwrightapp/goldwright-addon/issues/8))
- **Escape in combat:** Escape now closes Goldwright windows in combat too, like the game's own windows. On a shopping list, Escape still goes back to your lists first. ([#6](https://github.com/goldwrightapp/goldwright-addon/issues/6))
- **Close button in combat:** the X on Goldwright windows didn't work in combat ("Interface action failed because of an AddOn"). It now closes the window right away. ([#3](https://github.com/goldwrightapp/goldwright-addon/issues/3))
- **Bug reports:** `/gw bug` now notes when combat starts and ends, which windows were open, and any blocked action, from Goldwright or another add-on, so keyboard and combat problems can be traced.

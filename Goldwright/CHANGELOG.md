# Goldwright changelog

## 0.7.6

Urgent fix for PvP and Roleplay players: since Forever's latest client update, Goldwright could show Normal prices on every realm type.

- **Fix: prices from the right auction house again.** Forever's update on 20–21 November hides the realm from add-ons on purpose (it stops layer-jumping add-ons). Goldwright used the realm's name to know your realm type, so PvP, Roleplay and RP-PvP players were silently shown Normal prices, and players who had switched the Normal data off saw no prices at all. Goldwright now reads your realm type straight from the game's rules (whether PvP and Roleplay rules apply), which the update doesn't hide, so it's right from the moment you log in. ([#28](https://github.com/goldwrightapp/goldwright-addon/issues/28))
- **Your choice wins:** Settings › Ruleset still sets the realm type by hand. And if a future update ever hides the game's rules too, Goldwright asks you once (**Normal · PvP · RP · RP-PvP**) and remembers the answer for that character.
- **Your sales history and level plans** stay with your character after the update; they were filed under the realm's old name.
- **`/gw bug`** now shows where your realm type came from, to help with reports.
- **Bug reports keep the auction house lines:** fights are only noted in the report's log while a Goldwright window is open, so a questing session no longer pushes them out.

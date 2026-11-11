# Goldwright changelog

## 0.2.0-alpha

- **The real auction house cut:** when you open your mailbox, Goldwright reads the invoices of your sold auctions and learns each house's actual cut (Alliance, Horde, Blackwater). Profit and "you receive" numbers use it from then on; `/gw status` shows it.
- **Report a bug in one paste:** `/gw bug` (or Settings → Report a Bug) opens a ready-made report with your versions, region, ruleset, settings and Goldwright's recent log. Press Ctrl+C and paste it into the Discord or GitHub.
- **Selling at Blackwater:** in Booty Bay, Gadgetzan and Everlook the Sell tab and shopping lists use Blackwater's prices and its 15% cut.
- **Crafting:** a Goldwright window next to your profession window shows what each recipe costs, what it sells for and the profit per craft. Prices come from your faction's auction house; the Prices button switches to Blackwater, and recipes that really sell for more there say so. Thread, dye, salt and other vendor supplies count at the vendor price, and Goldwright learns the prices of anything vendors you visit sell. Drag the window anywhere and it opens there next time (`/gw craft reset` puts it back).
- **Goldwright Data comes with Goldwright:** installing the add-on in the CurseForge app or WowUp now installs the daily price data too.
- The launcher shows the website, **goldwright.app**.
- Behind the scenes: shared interface code and tidier documentation. Nothing else changes in game.

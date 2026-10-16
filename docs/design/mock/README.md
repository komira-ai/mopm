# mopm.dev v2 design mocks

Static HTML mocks of the pages proposed in [../mopm-dev.md](../mopm-dev.md), so the design can be judged before
anything is built. They are pictures you can open in a browser. They are not the site.

- **Illustrative data only.** Package names, owners, versions, dates and tokens are made up. A banner at the top of
  every page says so and names what is still planned.
- **No JavaScript.** No page has a `<script>`, an inline `style` attribute, a `<style>` element or an external resource
  (no fonts, images or CDNs). Everything is HTML plus one stylesheet, `mock.css`, matching the site's rules (CSP
  `'self'`, no inline script or style). Interactions are therefore static. Copy buttons do nothing. The "Copied" state
  is drawn, not triggered. The landing page's installer switcher and the `<details>` disclosures work through plain
  HTML and CSS. The typing effect in the landing page's search preview is a CSS animation, which stops when the
  system asks for reduced motion.
- **Light and dark.** Each page has a `-dark.html` twin that differs only in `data-theme="dark"` on `<html>`. The light
  pages follow the system setting.
- **Not the shipped CSS.** `mock.css` covers every page and both themes in one file. The site's per-route budgets
  (mopm-dev.md, section 4) apply to the build in PR 2, not to this file.

| file | page | note section |
|---|---|---|
| `index.html` | landing page | 5, Q7 |
| `package.html` | package page (README tab) | 1.5, 5 |
| `search.html` | search results for `json` | 1.4, 1.5, 3.6, 5 |
| `reference.html` | API reference for a struct | 2.4 to 2.6 |
| `account.html` | account page | 4.3, 4.4 |

## How to view

Open any `.html` file in a browser straight from a checkout (`file://` works, because nothing is fetched), or browse
the screenshots in [screens/](screens/). Those are full-page captures at 1440 px wide, plus 390 px wide for
`index-mobile.png` and `package-mobile.png`. They were taken with headless Chrome, then the empty space that the
page's minimum height leaves above the footer was trimmed.

# Notices

NamRig is © 2026 Avraham Ohana and is released under the **GNU General Public License v3.0**
(see `LICENSE`). If you distribute a modified version, you must publish its source under the same
license. The copyright holder may additionally distribute NamRig under other terms (for example on
the App Store).

## Third-party software

| Component | License | Notes |
|---|---|---|
| [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore) — © Steven Atkinson | MIT | The amp/pedal capture engine (`ThirdParty/NeuralAmpModelerCore`, vendored copy in `NamRig/NamRig/Engine/NAMCore`) |
| [AudioDSPTools](https://github.com/sdatkinson/AudioDSPTools) — © Steven Atkinson | MIT | Bundled with NeuralAmpModelerCore |
| [Eigen](https://eigen.tuxfamily.org) | MPL-2.0 | Linear algebra; Eigen's files remain under the MPL, unmodified |
| [nlohmann/json](https://github.com/nlohmann/json) — © Niels Lohmann | MIT | JSON parsing of `.nam` files |

The full license texts are in `ThirdParty/NeuralAmpModelerCore/LICENSE` and
`ThirdParty/NeuralAmpModelerCore/Dependencies/eigen/COPYING.*`, and are shown in-app under
Settings → Legal → Acknowledgements.

## Bundled capture

`NamRig/NamRig/Models/Bugera V5.nam` is a Neural Amp Modeler capture of the author's own amplifier,
made by the author. It is licensed under **CC BY 4.0** — use it freely, credit "Avraham Ohana / NamRig".
No other captures are bundled. Captures downloaded through TONE3000 belong to their creators and are
subject to TONE3000's terms; they must not be redistributed with the app.

## Trademarks

TONE3000 is a trademark of its owner; NamRig uses the TONE3000 API with the user's own account and is
not affiliated with or endorsed by TONE3000. Amplifier and pedal names that appear in captures or in
the stompbox model descriptions are the property of their respective owners and are used only to
describe the circuits and sounds being modeled; NamRig is not affiliated with any of them.

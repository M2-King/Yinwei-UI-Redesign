# three.js r128 (MIT) — vendored for the offline Listen Room page

The approved prototype was built on three.js r128 and its `examples/js` add-ons (global `THREE`).
r160, used by the laptop's workspace, has no `examples/js`, so this page keeps its own r128
(IMPLEMENTATION_IPAD_LISTEN_ROOM.md §2, "Why Three.js r128 here").

- Licence: MIT, Copyright 2010-2021 Three.js Authors (header kept in `three.min.js`).
- Downloaded 2026-10-19, unmodified:
  - `three.min.js` from cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js
  - `examples/...` from cdn.jsdelivr.net/npm/three@0.128.0/examples/js/...
- Checked before use: revision "128", the MIT header, and each add-on defines the class it should.

SHA-256 pins (checked by `test/listen_room/offline_contract_test.mjs`):

| SHA-256 | File | Bytes |
|---|---|---|
| `9274bbcec8d96168626c732b5d31c775aa8cfb7eaa0599bec0c175908a2c1ce2` `three.min.js` | | 603445 |
| `6b5da4fe3b410286974590885f82fe4a446f25c728f7d6c888e2a2a331333949` `examples/shaders/CopyShader.js` | | 606 |
| `00ed0682e61ca207d9c62298269472d6d4eedd9d33528400e7cbc633da8544da` `examples/shaders/LuminosityHighPassShader.js` | | 1228 |
| `77c8fdedf8f488b7cab5392afb2d55f1acadf9d9086961b61dfd28f7ae80bdc3` `examples/shaders/GammaCorrectionShader.js` | | 679 |
| `4fc320fa3185847797332bc2b0125b1a39b9cf5fc4170a2f180cfa54fb057a2b` `examples/postprocessing/EffectComposer.js` | | 6271 |
| `57a549b2d6a947cddf0385a804dc70c3b2d155663d908e99e35d42274b3878be` `examples/postprocessing/RenderPass.js` | | 1746 |
| `2e64890b8e4c4dafcfd796d5c84877f2ad36a101c83263211c500ec40eaf1240` `examples/postprocessing/ShaderPass.js` | | 1416 |
| `1ed342b273e9b077a3e92e5caeecd45043f03071306c696564d5b53f0562dced` `examples/postprocessing/UnrealBloomPass.js` | | 12612 |
| `a8db19d9af1a91c07f9da9620600ce1dbf4e18299edad6da8d51f5d1188effb8` `examples/objects/Reflector.js` | | 6849 |
| `5bad5d9e45d4d48bb713d924aec145dc6ea58be568357e50f131efa73a8639f5` `examples/geometries/RoundedBoxGeometry.js` | | 4757 |
| `4e74c34e958820047e3acc5fde3956f6e0fb4cd548c590228554ef86a806a269` `examples/utils/BufferGeometryUtils.js` | | 23040 |

The only addresses inside these files are reference links in comments and the XHTML namespace name
that three.js passes to `createElementNS`; nothing is fetched.

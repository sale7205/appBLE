# WaveRider Remote

Phone joystick for the WaveRider boat. Two front ends, one boat sketch. No IMU, no new parts: straight line comes from **trim**.

| Folder / file | What it is |
|---|---|
| `firmware/BoatESP_Remote/BoatESP_Remote.ino` | ESP32 boat sketch (replaces BoatESP_BLE.ino) |
| `index.html` | Web remote, open it in **Bluefy** |
| `ios/` | Native iPhone app (SwiftUI), install with **Sideloadly** |
| `.github/workflows/build-ipa.yml` | Builds the .ipa on GitHub's Mac, no Mac needed |

## 1. Boat (ESP32)

- Board: ESP32 Dev Module, Partition Scheme: **Huge APP**. No extra libraries (BLE and Preferences are built in).
- Same wiring as before. ENA/ENB stay HIGH, speed is PWM on IN1..IN4 (slow decay).
- Serial Monitor: 115200, line ending **Newline**. Old letters F, X, L, R, S still work (also from nRF Toolbox).

## 2. Web remote (Bluefy)

1. Put this repo on GitHub, then Settings > Pages > Deploy from branch > `main` / root.
2. On the iPhone open Bluefy, go to `https://<your-user>.github.io/<repo>/`, tap Connect, pick **WR-2-BOAT**.

## 3. iPhone app (Sideloadly)

No Mac: push the repo, go to the **Actions** tab > "Build iPhone app" > latest run > download **WaveRider-ipa** (unzip it to get `WaveRider.ipa`). Drag it into Sideloadly with your Apple ID. A free Apple ID install expires after 7 days, just sideload again.

With a Mac: `brew install xcodegen`, then in `ios/` run `xcodegen generate`, open `WaveRider.xcodeproj`, pick your team, run on the phone.

First launch: allow Bluetooth.

## 4. First test

Props out of the water:
1. Connect. Throttle up a little: both motors forward? If one runs backwards: Settings > Reverse left/right motor.
2. Steer right: the LEFT motor should speed up. If not: Swap left / right.
3. PWM_MIN: raise the throttle slowly, note where each motor starts turning, set PWM_MIN L / R a bit below that.

On the water, Manual:

4. Throttle to your normal speed, no steering. Which way does it curve?
5. **Learn trim:** drive forward again, hold the small steering that keeps it straight for about 3 s (the Learn trim button turns green), tap **Learn trim** while still driving.
6. Let go of steering. Still curving? Fine tune with the trim arrows (left arrow = go more left).
7. **Save to boat.** Trim is set for that speed, so learn it at the speed you'll use in the run.

## Trim

| Trim shows | Means | Use it when |
|---|---|---|
| `Left -6%` | left motor gets 6% less | boat curves RIGHT (right motor weak) |
| `Right -6%` | right motor gets 6% less | boat curves LEFT |

## Messages (phone to boat, text)

| Message | Meaning |
|---|---|
| `J,thr,steer` | sticks, -255..255, every 50 ms. No J for 500 ms = stop |
| `S` | STOP |
| `M,n` | mode 0 Manual, 1 Auto mission |
| `Q,n` | mission 1 start, 2 arrived, 3 next, 0 abort |
| `T,trim` | -50..50 %, + slows left, - slows right |
| `LT` | learn trim from the last ~3 s of driving |
| `N,minL,minR` | PWM where each motor starts |
| `V,max` | speed limit |
| `D,dz,expo,ramp` | stick deadzone %, expo %, ramp per 20 ms |
| `I,invL,invR,swap` | motor directions, 0/1 |
| `E,legMs,holdMs,autoThr` | auto mission leg time, hold time, throttle |
| `SAVE` / `GET` | save to flash / send settings |

Boat to phone: `H,pwmL,pwmR,mode,station,missionState,flags,trim` 5 times a second (flags: 1 stick stream on, 2 watchdog stop, 4 learn trim ready), `CFG,trim,minL,minR,max,dz,expo,ramp,invL,invR,swap,legMs,holdMs,autoThr` after GET, other lines are status messages.

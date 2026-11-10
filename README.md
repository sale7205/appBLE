# WaveRider Remote

Phone joystick for the WaveRider boat. Two front ends, one boat sketch:

| Folder / file | What it is |
|---|---|
| `firmware/BoatESP_Remote/BoatESP_Remote.ino` | ESP32 boat sketch (replaces BoatESP_BLE.ino) |
| `index.html` | Web remote, open it in **Bluefy** |
| `ios/` | Native iPhone app (SwiftUI), install with **Sideloadly** |
| `.github/workflows/build-ipa.yml` | Builds the .ipa on GitHub's Mac, no Mac needed |

## 1. Boat (ESP32)

- Board: ESP32 Dev Module, Partition Scheme: **Huge APP**. No extra libraries (BLE, Wire, Preferences are built in).
- Same wiring as before. ENA/ENB stay HIGH, speed is PWM on IN1..IN4 (slow decay).
- Optional IMU for Assist / Auto heading hold: **MPU6050 (GY-521)**
  - VCC to 3V3, GND to GND, SDA to P21, SCL to P22
  - Mount it flat, near the middle of the boat, boat still at power on (gyro calibrates).
  - No IMU: Manual works, the app shows "No IMU".
- Serial Monitor: 115200, line ending **Newline**. Old letters F, X, L, R, S still work (also from nRF Toolbox).

## 2. Web remote (Bluefy)

1. Put this repo on GitHub, then Settings > Pages > Deploy from branch > `main` / root.
2. On the iPhone open Bluefy, go to `https://<your-user>.github.io/<repo>/`, tap Connect, pick **WR-2-BOAT**.

## 3. iPhone app (Sideloadly)

No Mac: push the repo, go to the **Actions** tab > "Build iPhone app" > latest run > download **WaveRider-ipa** (unzip it to get `WaveRider.ipa`). Drag it into Sideloadly with your Apple ID. A free Apple ID install expires after 7 days, just sideload again.

With a Mac: `brew install xcodegen`, then in `ios/` run `xcodegen generate`, open `WaveRider.xcodeproj`, pick your team, run on the phone.

First launch: allow Bluetooth.

## 4. First test (props out of the water)

1. Connect. Throttle up a little: both motors forward? If one runs backwards: Settings > Reverse left/right motor.
2. Steer right: the LEFT motor should speed up. If not: Swap left / right.
3. PWM_MIN: raise the throttle slowly, note where each motor starts turning, set PWM_MIN L / R a bit below that.
4. With the IMU: turn the boat right by hand, Heading should go up. If it goes down: Flip gyro.
5. Save to boat.
6. On the water in Manual, find the trim that goes straight (right motor slower = negative trim). Save.
7. Assist: KD 0, raise KP until it snakes, halve it, add KD until the snaking stops. Save.

## Messages (phone to boat, text)

| Message | Meaning |
|---|---|
| `J,thr,steer` | sticks, -255..255, every 50 ms. No J for 500 ms = stop |
| `S` | STOP |
| `M,n` | mode 0 Manual, 1 Assist, 2 Auto |
| `Q,n` | mission 1 start, 2 arrived, 3 next, 0 abort |
| `T,trim` | -50..50 %, + slows left, - slows right |
| `K,kp,kd` | PD gains |
| `N,minL,minR` | PWM where each motor starts |
| `V,max` | speed limit |
| `D,dz,expo,ramp` | stick deadzone %, expo %, ramp per 20 ms |
| `I,invL,invR,swap,invGyro` | directions, 0/1 |
| `E,legMs,holdMs,autoThr` | auto mission leg time, hold time, throttle |
| `CAL` / `SAVE` / `GET` | calibrate gyro / save to flash / send settings |

Boat to phone: `H,heading*10,target*10,pwmL,pwmR,mode,station,missionState,flags` 5 times a second, `CFG,...` after GET, other lines are status messages.

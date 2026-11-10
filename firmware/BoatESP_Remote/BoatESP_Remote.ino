// WaveRider boat ESP32: phone joystick + slow-decay PWM + trim (+ learn trim) + timed auto mission
// Board: ESP32 Dev Module, Partition Scheme: Huge APP
// Talks to: WaveRider iPhone app, the Bluefy web page, nRF Toolbox UART, Serial Monitor (115200, Newline)

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>

#define BLE_DEVICE_NAME "WR-2-BOAT"
#define SERVICE_UUID    "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CMD_CHAR_UUID   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_CHAR_UUID    "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// Left motor (H-bridge OUT1 / OUT2)
#define ENA 25
#define M1A 26
#define M1B 27

// Right motor (H-bridge OUT3 / OUT4)
#define ENB 14
#define M2A 32
#define M2B 33

#define STATION_PIN 13          // HIGH while the boat holds at a station (optional wire)

#define CONTROL_DT_MS 20        // control loop 50 Hz
#define TELEMETRY_MS  200       // H line to the phone 5 Hz
#define WATCHDOG_MS   500       // no J for 500 ms = stop
#define LEGACY_SPEED  200       // speed for the old single letters (F, X, L, R)
#define NUM_STATIONS  5

#define LEARN_MIN_PWM 60        // learn trim only counts when both motors get at least this
#define LEARN_MIN_MS  2000      // and after this long of driving forward
#define LEARN_TAU     1.5       // averaging time, seconds

#define MODE_MANUAL 0
#define MODE_AUTO   1

#define MS_IDLE 0
#define MS_LEG  1
#define MS_HOLD 2
#define MS_DONE 3

#define RX_QUEUE 8
#define RX_LEN   64

// ---------------- settings (saved in flash with SAVE) ----------------
struct Settings {
  int  trim;      // -50..50 %. + slows the left motor, - slows the right motor
  int  minL;      // PWM where the left motor starts turning
  int  minR;      // PWM where the right motor starts turning
  int  maxPwm;    // speed limit
  int  deadzone;  // steering stick deadzone, %
  int  expo;      // steering expo, %
  int  ramp;      // max PWM change per 20 ms (0 = no ramp)
  bool invL;
  bool invR;
  bool swapLR;
  int  legMs;     // auto mission: drive time per leg
  int  holdMs;    // auto mission: stop time at each station
  int  autoThr;   // auto mission: throttle on each leg
};

Settings cfg;
Preferences prefs;

// ---------------- BLE ----------------
BLECharacteristic* pTxChar = nullptr;
bool deviceConnected = false;
bool wasConnected    = false;

char rxQueue[RX_QUEUE][RX_LEN];
volatile uint8_t rxHead  = 0;
volatile uint8_t rxCount = 0;
portMUX_TYPE rxMux = portMUX_INITIALIZER_UNLOCKED;

char serialLine[RX_LEN];
uint8_t serialLen = 0;

// ---------------- control state ----------------
int   mode       = MODE_MANUAL;
int   stickThr   = 0;        // -255..255, stays where the phone leaves it
int   stickSteer = 0;        // -255..255
bool  joyActive  = false;    // J stream running (watchdog on)
bool  watchdogTripped = false;
unsigned long lastJoyMs = 0;

float outL = 0, outR = 0;    // after ramp, -255..255
int   pwmL = 0, pwmR = 0;    // what actually goes to the pins (signed)

float learnL = 0, learnR = 0;   // average left/right command while driving forward
float learnMs = 0;              // how long that average has been running

int   missionState = MS_IDLE;
int   station      = 0;
unsigned long stateStartMs = 0;

unsigned long lastControlMs   = 0;
unsigned long lastTelemetryMs = 0;

// =====================================================================
void notifyLine(const char* msg) {
  if (deviceConnected && pTxChar != nullptr) {
    pTxChar->setValue((uint8_t*)msg, strlen(msg));
    pTxChar->notify();
  }
}

void reply(const char* msg) {
  Serial.println(msg);
  notifyLine(msg);
}

// ---------------- settings ----------------
void setDefaults() {
  cfg.trim = 0;
  cfg.minL = 60; cfg.minR = 60;
  cfg.maxPwm = 255;
  cfg.deadzone = 5; cfg.expo = 30; cfg.ramp = 10;
  cfg.invL = false; cfg.invR = false; cfg.swapLR = false;
  cfg.legMs = 4000; cfg.holdMs = 12000; cfg.autoThr = 180;
}

void loadSettings() {
  setDefaults();
  prefs.begin("wr2", true);
  cfg.trim     = prefs.getInt("trim", cfg.trim);
  cfg.minL     = prefs.getInt("minL", cfg.minL);
  cfg.minR     = prefs.getInt("minR", cfg.minR);
  cfg.maxPwm   = prefs.getInt("max", cfg.maxPwm);
  cfg.deadzone = prefs.getInt("dz", cfg.deadzone);
  cfg.expo     = prefs.getInt("expo", cfg.expo);
  cfg.ramp     = prefs.getInt("ramp", cfg.ramp);
  cfg.invL     = prefs.getBool("invL", cfg.invL);
  cfg.invR     = prefs.getBool("invR", cfg.invR);
  cfg.swapLR   = prefs.getBool("swap", cfg.swapLR);
  cfg.legMs    = prefs.getInt("legMs", cfg.legMs);
  cfg.holdMs   = prefs.getInt("holdMs", cfg.holdMs);
  cfg.autoThr  = prefs.getInt("autoThr", cfg.autoThr);
  prefs.end();
}

void saveSettings() {
  prefs.begin("wr2", false);
  prefs.putInt("trim", cfg.trim);
  prefs.putInt("minL", cfg.minL);
  prefs.putInt("minR", cfg.minR);
  prefs.putInt("max", cfg.maxPwm);
  prefs.putInt("dz", cfg.deadzone);
  prefs.putInt("expo", cfg.expo);
  prefs.putInt("ramp", cfg.ramp);
  prefs.putBool("invL", cfg.invL);
  prefs.putBool("invR", cfg.invR);
  prefs.putBool("swap", cfg.swapLR);
  prefs.putInt("legMs", cfg.legMs);
  prefs.putInt("holdMs", cfg.holdMs);
  prefs.putInt("autoThr", cfg.autoThr);
  prefs.end();
  reply("Settings saved");
}

void sendConfig() {
  char line[120];
  snprintf(line, sizeof(line), "CFG,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
           cfg.trim, cfg.minL, cfg.minR, cfg.maxPwm,
           cfg.deadzone, cfg.expo, cfg.ramp,
           cfg.invL, cfg.invR, cfg.swapLR,
           cfg.legMs, cfg.holdMs, cfg.autoThr);
  reply(line);
}

// ---------------- motors (slow decay: EN held HIGH, PWM on one IN pin) ----------------
int driveMotor(int pinA, int pinB, float v, int pwmMin, bool inv) {
  float cmd = v;                    // keep the sign before reversing, for the phone display
  if (inv) v = -v;
  int mag  = (int)fabs(v);
  int duty = 0;
  if (mag >= 1) {
    duty = pwmMin + (long)mag * (255 - pwmMin) / 255;   // jump over the dead zone
    duty = constrain(duty, 0, 255);
  }
  if (v > 0 && duty > 0) {          // forward: PWM on A, B low. Off-time = both low = brake/recirculate
    analogWrite(pinA, duty);
    analogWrite(pinB, 0);
  } else if (v < 0 && duty > 0) {   // reverse
    analogWrite(pinA, 0);
    analogWrite(pinB, duty);
  } else {                          // both low = brake
    analogWrite(pinA, 0);
    analogWrite(pinB, 0);
    duty = 0;
  }
  return (cmd >= 0) ? duty : -duty;
}

void writeMotors() {
  if (cfg.swapLR) {
    pwmL = driveMotor(M2A, M2B, outL, cfg.minL, cfg.invL);
    pwmR = driveMotor(M1A, M1B, outR, cfg.minR, cfg.invR);
  } else {
    pwmL = driveMotor(M1A, M1B, outL, cfg.minL, cfg.invL);
    pwmR = driveMotor(M2A, M2B, outR, cfg.minR, cfg.invR);
  }
}

void stopMotors() {
  outL = 0;
  outR = 0;
  analogWrite(M1A, 0);
  analogWrite(M1B, 0);
  analogWrite(M2A, 0);
  analogWrite(M2B, 0);
  pwmL = 0;
  pwmR = 0;
}

void stopAll() {
  stickThr   = 0;
  stickSteer = 0;
  joyActive  = false;
  learnMs    = 0;
  stopMotors();
}

// ---------------- learn trim ----------------
// Drive forward in Manual, hold whatever steering keeps the boat straight for 3 s,
// then send LT. The steering you were holding becomes the trim.
void learnTrim() {
  if (learnMs < LEARN_MIN_MS || learnL < 1 || learnR < 1) {
    reply("Learn trim: drive straight forward for 3 s first, then press it while still driving");
    return;
  }
  float ratio = learnL / learnR;    // left/right split that kept the boat straight
  int t;
  if (ratio < 1.0) t = (int)(100.0 * (1.0 - ratio) + 0.5);          // needed less left: slow left (+)
  else             t = -(int)(100.0 * (1.0 - 1.0 / ratio) + 0.5);   // needed less right: slow right (-)
  cfg.trim = constrain(t, -50, 50);
  char msg[64];
  snprintf(msg, sizeof(msg), "Trim learned: %d%%. Press Save to keep it", cfg.trim);
  reply(msg);
  sendConfig();
}

// ---------------- mission (timed legs, trim keeps it straight) ----------------
void beginHold() {
  missionState = MS_HOLD;
  stateStartMs = millis();
  digitalWrite(STATION_PIN, HIGH);
  char msg[32];
  snprintf(msg, sizeof(msg), "At station %d, holding", station);
  reply(msg);
}

void startLeg() {
  missionState = MS_LEG;
  stateStartMs = millis();
  char msg[32];
  snprintf(msg, sizeof(msg), "Leg to station %d", station);
  reply(msg);
}

void endHold() {
  digitalWrite(STATION_PIN, LOW);
  if (station >= NUM_STATIONS) {
    missionState = MS_DONE;
    reply("Mission done");
    return;
  }
  station++;
  startLeg();
}

void abortMission() {
  if (missionState != MS_IDLE) reply("Mission aborted");
  missionState = MS_IDLE;
  station = 0;
  digitalWrite(STATION_PIN, LOW);
}

void startMission() {
  stopAll();
  mode = MODE_AUTO;
  station = 1;
  startLeg();
}

// ---------------- messages ----------------
void handleLegacy(char c) {
  switch (toupper(c)) {
    case 'F': case 'W': case 'M':
      mode = MODE_MANUAL; abortMission(); joyActive = false;
      stickThr = LEGACY_SPEED;      stickSteer = 0;                  reply("Forward");  break;
    case 'X': case 'B':
      mode = MODE_MANUAL; abortMission(); joyActive = false;
      stickThr = -LEGACY_SPEED;     stickSteer = 0;                  reply("Backward"); break;
    case 'L': case 'A':
      mode = MODE_MANUAL; abortMission(); joyActive = false;
      stickThr = LEGACY_SPEED / 2;  stickSteer = -LEGACY_SPEED / 2;  reply("Left");     break;
    case 'R': case 'D':
      mode = MODE_MANUAL; abortMission(); joyActive = false;
      stickThr = LEGACY_SPEED / 2;  stickSteer = LEGACY_SPEED / 2;   reply("Right");    break;
    case 'S':
      abortMission(); stopAll();                                     reply("Stop");     break;
    default:
      Serial.print("Unknown command: '");
      Serial.print(c);
      Serial.println("'");
      reply("Unknown command");
      break;
  }
}

void handleMessage(char* line) {
  while (*line == ' ') line++;
  int n = strlen(line);
  while (n > 0 && line[n - 1] == ' ') line[--n] = '\0';
  if (n == 0) return;

  if (n == 1) {
    handleLegacy(line[0]);
    return;
  }

  if (strcmp(line, "GET") == 0)  { sendConfig();   return; }
  if (strcmp(line, "SAVE") == 0) { saveSettings(); return; }
  if (strcmp(line, "LT") == 0)   { learnTrim();    return; }

  // split "X,a,b,c" into tokens
  char* tok[16];
  int count = 0;
  char* p = strtok(line, ",");
  while (p != nullptr && count < 16) {
    tok[count++] = p;
    p = strtok(nullptr, ",");
  }
  if (count == 0) return;
  char cmd = toupper(tok[0][0]);

  if (cmd == 'J' && count >= 3) {
    stickThr   = constrain(atoi(tok[1]), -255, 255);
    stickSteer = constrain(atoi(tok[2]), -255, 255);
    lastJoyMs  = millis();
    joyActive  = true;
    watchdogTripped = false;
    return;
  }

  char msg[48];
  if (cmd == 'M' && count >= 2) {
    abortMission();
    stopMotors();
    mode = constrain(atoi(tok[1]), 0, 1);
    reply(mode == MODE_MANUAL ? "Mode Manual" : "Mode Auto");
  } else if (cmd == 'Q' && count >= 2) {
    int q = atoi(tok[1]);
    if (q == 1) startMission();
    else if (q == 0) { abortMission(); stopAll(); }
    else if (q == 2) { if (missionState == MS_LEG) beginHold(); }
    else if (q == 3) {
      if (missionState == MS_LEG) beginHold();
      else if (missionState == MS_HOLD) endHold();
    }
  } else if (cmd == 'T' && count >= 2) {
    cfg.trim = constrain(atoi(tok[1]), -50, 50);
    snprintf(msg, sizeof(msg), "Trim %d%%", cfg.trim);
    reply(msg);
  } else if (cmd == 'N' && count >= 3) {
    cfg.minL = constrain(atoi(tok[1]), 0, 254);
    cfg.minR = constrain(atoi(tok[2]), 0, 254);
    snprintf(msg, sizeof(msg), "PWM_MIN L %d R %d", cfg.minL, cfg.minR);
    reply(msg);
  } else if (cmd == 'V' && count >= 2) {
    cfg.maxPwm = constrain(atoi(tok[1]), 0, 255);
    snprintf(msg, sizeof(msg), "Speed limit %d", cfg.maxPwm);
    reply(msg);
  } else if (cmd == 'D' && count >= 4) {
    cfg.deadzone = constrain(atoi(tok[1]), 0, 50);
    cfg.expo     = constrain(atoi(tok[2]), 0, 100);
    cfg.ramp     = constrain(atoi(tok[3]), 0, 255);
    snprintf(msg, sizeof(msg), "DZ %d Expo %d Ramp %d", cfg.deadzone, cfg.expo, cfg.ramp);
    reply(msg);
  } else if (cmd == 'I' && count >= 4) {
    cfg.invL   = atoi(tok[1]) != 0;
    cfg.invR   = atoi(tok[2]) != 0;
    cfg.swapLR = atoi(tok[3]) != 0;
    stopMotors();
    reply("Motor directions set");
  } else if (cmd == 'E' && count >= 4) {
    cfg.legMs   = constrain(atoi(tok[1]), 500, 60000);
    cfg.holdMs  = constrain(atoi(tok[2]), 0, 120000);
    cfg.autoThr = constrain(atoi(tok[3]), 0, 255);
    snprintf(msg, sizeof(msg), "Leg %d ms Hold %d ms Thr %d", cfg.legMs, cfg.holdMs, cfg.autoThr);
    reply(msg);
  } else {
    reply("Unknown command");
  }
}

void readSerial() {
  while (Serial.available() > 0) {
    char c = Serial.read();
    if (c == '\r' || c == '\n') {
      if (serialLen > 0) {
        serialLine[serialLen] = '\0';
        handleMessage(serialLine);
        serialLen = 0;
      }
    } else if (serialLen < RX_LEN - 1) {
      serialLine[serialLen++] = c;
    }
  }
}

void readBle() {
  while (true) {
    char line[RX_LEN];
    bool got = false;
    portENTER_CRITICAL(&rxMux);
    if (rxCount > 0) {
      memcpy(line, rxQueue[rxHead], RX_LEN);
      rxHead = (rxHead + 1) % RX_QUEUE;
      rxCount--;
      got = true;
    }
    portEXIT_CRITICAL(&rxMux);
    if (!got) return;

    // one write can carry several lines
    char* start = line;
    for (char* q = line; ; q++) {
      if (*q == '\n' || *q == '\r' || *q == '\0') {
        bool end = (*q == '\0');
        *q = '\0';
        if (strlen(start) > 0) handleMessage(start);
        if (end) break;
        start = q + 1;
      }
    }
  }
}

// ---------------- control loop ----------------
float shapeSteer(int s) {
  float x  = s / 255.0;
  float dz = cfg.deadzone / 100.0;
  float ax = fabs(x);
  if (ax < dz) return 0;
  x = (x > 0 ? 1 : -1) * (ax - dz) / (1.0 - dz);
  float e = cfg.expo / 100.0;
  x = (1.0 - e) * x + e * x * x * x;
  return x * 255.0;
}

void controlStep(float dt) {
  unsigned long now = millis();

  // watchdog: phone stopped sending J
  if (joyActive && now - lastJoyMs > WATCHDOG_MS) {
    stopAll();
    if (!watchdogTripped) {
      reply("Watchdog: no stick data, motors stopped");
      watchdogTripped = true;
    }
  }

  float thr   = stickThr;
  float steer = shapeSteer(stickSteer);

  if (mode == MODE_AUTO) {
    steer = 0;
    if (missionState == MS_LEG) {
      thr = cfg.autoThr;
      if (now - stateStartMs >= (unsigned long)cfg.legMs) beginHold();
    } else {
      thr = 0;
      if (missionState == MS_HOLD && now - stateStartMs >= (unsigned long)cfg.holdMs) endHold();
    }
  }

  // mix, steering gets priority when a side saturates
  float L = thr + steer;
  float R = thr - steer;
  float over = max(fabs(L), fabs(R)) - 255.0;
  if (over > 0) {
    if (thr > 0)      thr = max(0.0f, thr - over);
    else if (thr < 0) thr = min(0.0f, thr + over);
    L = constrain(thr + steer, -255.0, 255.0);
    R = constrain(thr - steer, -255.0, 255.0);
  }

  // speed limit
  L = L * cfg.maxPwm / 255.0;
  R = R * cfg.maxPwm / 255.0;

  // trim: slow down the stronger motor
  if (cfg.trim > 0)      L *= (1.0 - cfg.trim / 100.0);
  else if (cfg.trim < 0) R *= (1.0 + cfg.trim / 100.0);

  // learn trim: keep a running average while driving forward in Manual
  if (mode == MODE_MANUAL && L >= LEARN_MIN_PWM && R >= LEARN_MIN_PWM) {
    if (learnMs == 0) {
      learnL = L;
      learnR = R;
    } else {
      float a = dt / LEARN_TAU;
      learnL += a * (L - learnL);
      learnR += a * (R - learnR);
    }
    learnMs += dt * 1000.0;
  } else {
    learnMs = 0;
  }

  // ramp
  if (cfg.ramp > 0) {
    outL += constrain(L - outL, (float)-cfg.ramp, (float)cfg.ramp);
    outR += constrain(R - outR, (float)-cfg.ramp, (float)cfg.ramp);
  } else {
    outL = L;
    outR = R;
  }

  writeMotors();
}

void sendTelemetry() {
  if (!deviceConnected) return;
  char line[48];
  int flags = (joyActive ? 1 : 0) | (watchdogTripped ? 2 : 0) | (learnMs >= LEARN_MIN_MS ? 4 : 0);
  snprintf(line, sizeof(line), "H,%d,%d,%d,%d,%d,%d,%d",
           pwmL, pwmR, mode, station, missionState, flags, cfg.trim);
  notifyLine(line);
}

// ---------------- BLE callbacks ----------------
class BoatServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    auto value = pCharacteristic->getValue();
    int len = value.length();
    if (len <= 0) return;
    if (len > RX_LEN - 1) len = RX_LEN - 1;

    portENTER_CRITICAL(&rxMux);
    if (rxCount == RX_QUEUE) {             // full: drop the oldest
      rxHead = (rxHead + 1) % RX_QUEUE;
      rxCount--;
    }
    uint8_t tail = (rxHead + rxCount) % RX_QUEUE;
    for (int i = 0; i < len; i++) rxQueue[tail][i] = value[i];
    rxQueue[tail][len] = '\0';
    rxCount++;
    portEXIT_CRITICAL(&rxMux);
  }
};

void Init_BLE() {
  BLEDevice::init(BLE_DEVICE_NAME);
  BLEDevice::setMTU(185);

  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new BoatServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  BLECharacteristic* pCmdChar = pService->createCharacteristic(
      CMD_CHAR_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pCmdChar->setCallbacks(new CommandCallbacks());

  pTxChar = pService->createCharacteristic(
      TX_CHAR_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  pTxChar->addDescriptor(new BLE2902());

  pService->start();

  BLEDevice::startAdvertising();
  Serial.println("BLE advertising as " BLE_DEVICE_NAME);
}

// =====================================================================
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("Start WaveRider boat...");

  pinMode(ENA, OUTPUT);
  pinMode(M1A, OUTPUT);
  pinMode(M1B, OUTPUT);
  pinMode(ENB, OUTPUT);
  pinMode(M2A, OUTPUT);
  pinMode(M2B, OUTPUT);
  pinMode(STATION_PIN, OUTPUT);
  digitalWrite(STATION_PIN, LOW);

  stopMotors();
  digitalWrite(ENA, HIGH);   // EN stays HIGH: speed is PWM on the IN pins (slow decay)
  digitalWrite(ENB, HIGH);

  loadSettings();
  Serial.print("Settings loaded, trim ");
  Serial.print(cfg.trim);
  Serial.println("%");

  Init_BLE();

  lastControlMs   = millis();
  lastTelemetryMs = millis();
  Serial.println("WaveRider boat Ready. Serial Monitor: 115200, line ending Newline. F/X/L/R/S still work");
}

void loop() {
  readSerial();
  readBle();

  unsigned long now = millis();

  if (now - lastControlMs >= CONTROL_DT_MS) {
    float dt = (now - lastControlMs) / 1000.0;
    if (dt > 0.2) dt = CONTROL_DT_MS / 1000.0;
    lastControlMs = now;
    controlStep(dt);
  }

  if (now - lastTelemetryMs >= TELEMETRY_MS) {
    lastTelemetryMs = now;
    sendTelemetry();
  }

  if (deviceConnected && !wasConnected) {
    Serial.println("Phone connected");
    wasConnected = true;
  }

  if (!deviceConnected && wasConnected) {
    abortMission();
    stopAll();
    Serial.println("Phone disconnected, motors stopped");
    delay(500);
    BLEDevice::startAdvertising();
    Serial.println("Advertising again");
    wasConnected = false;
  }
}

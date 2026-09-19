/*
 * ShelfScan BLE Gripper Controller
 *
 * Commands received from the phone:
 *
 *   T<dir><ms>  — timed move (non-blocking)
 *                 dir 0 = open, dir 1 = close
 *                 ms  = duration in milliseconds (1–9999)
 *                 e.g. "T0800" = open for 800 ms then stop
 *                      "T11200" = close for 1200 ms then stop
 *
 *   S           — stop immediately (emergency)
 *
 *   H           — home: open direction for FULL_TRAVEL_MS, resets position reference
 *
 * Speed is fixed at MOVE_SPEED / MOVE_SPEED_REV below.
 * For 360° continuous servos: 90 = stop, <90 = one dir, >90 = other dir.
 *
 * Wiring:
 *   Servo signal -> GPIO 18  (change SERVO_PIN if different)
 *   Servo power  -> battery +
 *   Servo GND    -> battery - (shared with ESP32 GND)
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ESP32Servo.h>

// ── Config ────────────────────────────────────────────────────────────────────
#define SERVO_PIN       18
#define MOVE_SPEED      45    // angle for open direction  (45 = ~half speed)
#define MOVE_SPEED_REV  135   // angle for close direction (135 = ~half speed)
#define FULL_TRAVEL_MS  3000  // ms for full open→close travel (tune to your mechanism)

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

// ── State ─────────────────────────────────────────────────────────────────────
Servo myServo;
BLECharacteristic *pCharacteristic;
bool deviceConnected = false;

unsigned long stopAt   = 0;   // millis() value when we should auto-stop
bool          moving   = false;

// ── Helpers ───────────────────────────────────────────────────────────────────
void stopServo() {
  myServo.write(90);
  moving = false;
}

void startMove(bool openDir, unsigned long durationMs) {
  myServo.write(openDir ? MOVE_SPEED : MOVE_SPEED_REV);
  stopAt  = millis() + durationMs;
  moving  = true;
}

// ── BLE callbacks ─────────────────────────────────────────────────────────────
class MyCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pChar) {
    String value = pChar->getValue().c_str();
    if (value.length() == 0) return;

    Serial.print("CMD: "); Serial.println(value);

    char cmd = value.charAt(0);

    if (cmd == 'T' && value.length() >= 3) {
      // T<dir><ms>  e.g. "T0800" or "T11200"
      bool openDir      = (value.charAt(1) == '0');
      unsigned long ms  = (unsigned long)value.substring(2).toInt();
      ms = constrain(ms, 1, 9999);
      startMove(openDir, ms);

    } else if (cmd == 'S') {
      stopServo();

    } else if (cmd == 'H') {
      // Home: open direction for full travel, resets position reference
      startMove(true, FULL_TRAVEL_MS);
    }
  }
};

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *pServer) {
    deviceConnected = true;
    Serial.println("Phone connected");
  }
  void onDisconnect(BLEServer *pServer) {
    deviceConnected = false;
    stopServo();
    Serial.println("Phone disconnected — restarting advertising");
    pServer->getAdvertising()->start();
  }
};

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  Serial.println("ShelfScan Gripper starting...");

  myServo.attach(SERVO_PIN);
  stopServo();

  BLEDevice::init("ShelfScan-Servo");
  BLEServer   *pServer  = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService  *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ            |
    BLECharacteristic::PROPERTY_WRITE           |
    BLECharacteristic::PROPERTY_WRITE_NR        |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->setCallbacks(new MyCallbacks());
  pCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdv = BLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("Ready. Waiting for phone...");
}

// ── Loop ──────────────────────────────────────────────────────────────────────
void loop() {
  // Auto-stop after timed move completes
  if (moving && millis() >= stopAt) {
    stopServo();
    Serial.println("Move complete");
  }
  delay(10);
}

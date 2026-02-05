#include <OneWire.h>
#include <DallasTemperature.h>
#include <SoftwareSerial.h>
#include <RTClib.h>

// --- Настройки пинов ---
#define ONE_WIRE_BUS_1 2     // Датчик DS18B20 #1 на D2
#define ONE_WIRE_BUS_2 4     // Датчик DS18B20 #2 на D4
#define RS485_RX     10      // RO модуля RS485 на D10
#define RS485_TX     11      // DI модуля RS485 на D11
#define RS485_CTRL   3       // DE и RE (вместе) на D3

#define DISPLAY_ADDR 1       // Адрес модуля

OneWire oneWire1(ONE_WIRE_BUS_1);
OneWire oneWire2(ONE_WIRE_BUS_2);
DallasTemperature sensors1(&oneWire1);
DallasTemperature sensors2(&oneWire2);
SoftwareSerial rs485(RS485_RX, RS485_TX);
RTC_DS3231 rtc;

void setup() {
  Serial.begin(9600);
  rs485.begin(9600);
  
  pinMode(RS485_CTRL, OUTPUT);
  digitalWrite(RS485_CTRL, LOW);

  sensors1.begin();
  sensors2.begin();
  rtc.begin();
  Serial.println("System Started");
}

String formatForDisplay(String textToSend) {
  // --- ЛОГИКА ЦЕНТРИРОВАНИЯ (С ПРИЖИМОМ ВПРАВО) ---

  // 1. Считаем визуальную длину (минус точка)
  int visualLen = textToSend.length();
  if (textToSend.indexOf('.') >= 0) {
    visualLen = visualLen - 1;
  }

  // 2. Считаем количество пустых клеток
  int emptySlots = 4 - visualLen;

  // 3. Вычисляем отступ слева
  if (emptySlots > 0) {
    // Формула (emptySlots + 1) / 2 обеспечивает сдвиг вправо при нечетном остатке.
    // Если пусто 2 места: (2+1)/2 = 1 пробел слева (Центр).
    // Если пусто 1 место: (1+1)/2 = 1 пробел слева (Прижат вправо).
    int leftPadding = (emptySlots + 1) / 2;

    for (int i = 0; i < leftPadding; i++) {
      textToSend = " " + textToSend;
    }
  }

  // 4. Добиваем пробелами справа (если остались пустые места после центровки)
  while (true) {
     int currentVisualLen = textToSend.length();
     if (textToSend.indexOf('.') >= 0) currentVisualLen--;

     if (currentVisualLen < 4) {
       textToSend += " ";
     } else {
       break;
     }
  }

  return textToSend;
}

void loop() {
  static uint8_t displayMode = 0;
  static unsigned long lastSwitchMs = 0;

  unsigned long nowMs = millis();
  unsigned long modeDurationMs = 50000UL;
  if (displayMode == 1 || displayMode == 2) {
    modeDurationMs = 5000UL;
  }

  if (nowMs - lastSwitchMs >= modeDurationMs) {
    displayMode = (displayMode + 1) % 3;
    lastSwitchMs = nowMs;
  }

  String textToSend;

  if (displayMode == 0) {
    DateTime now = rtc.now();
    char timeBuffer[6];
    snprintf(timeBuffer, sizeof(timeBuffer), "%02d.%02d", now.hour(), now.minute());
    textToSend = String(timeBuffer);
  } else {
    DallasTemperature* activeSensors = &sensors1;
    if (displayMode == 2) {
      activeSensors = &sensors2;
    }

    activeSensors->requestTemperatures();
    float tempC = activeSensors->getTempCByIndex(0);

    if (tempC == DEVICE_DISCONNECTED_C) {
      textToSend = "Err ";
    } else {
      // Формируем строку (без дроби для больших чисел, с дробью для обычных)
      if (tempC <= -100.0 || tempC >= 1000.0) {
        textToSend = String(tempC, 0);
      } else {
        textToSend = String(tempC, 1);
      }
    }
  }

  textToSend = formatForDisplay(textToSend);

  // Отправка
  Serial.print("T: "); Serial.println(textToSend);
  sendToDisplay(DISPLAY_ADDR, textToSend);
  delay(2000);
}

// Функция отправки пакета
void sendToDisplay(uint16_t address, String text) {
  uint8_t buffer[64];
  int idx = 0;
  buffer[idx++] = 0x02;
  addByte(buffer, idx, (address >> 8) & 0xFF);
  addByte(buffer, idx, address & 0xFF);
  addByte(buffer, idx, 0x2E);
  for (unsigned int i = 0; i < text.length(); i++) {
    addByte(buffer, idx, text[i]);
  }
  addByte(buffer, idx, 0xFF);
  buffer[idx++] = 0x03;

  digitalWrite(RS485_CTRL, HIGH);
  delay(2);
  rs485.write(buffer, idx);
  rs485.flush();
  digitalWrite(RS485_CTRL, LOW);
}

void addByte(uint8_t* buf, int &index, uint8_t val) {
  if (val == 0x02 || val == 0x03 || val == 0x09) buf[index++] = 0x09;
  buf[index++] = val;
}

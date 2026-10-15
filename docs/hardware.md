# External hardware

The chip has only digital pins. Anything analog or electrical (pull-ups,
transceivers, level shifting, line drivers, magnetics) goes on a Pmod or
the target board. This page lists what each protocol needs. Pin and pad
figures come from the Tiny Tapeout
[pinout](https://tinytapeout.com/specs/pinouts/),
[GPIO](https://tinytapeout.com/specs/gpio/),
[clock](https://tinytapeout.com/specs/clock/) and
[demo board](https://tinytapeout.com/specs/pcb-etr/) pages. The GPIO and
clock limits were characterized on earlier shuttles, so re-check them for
the IHP CMOS5L pads.

## Board and pads

- **I/O voltage:** 3.3 V on the demo board. Inputs are **not 5 V tolerant**.
- **Drive strength:** 4 mA source/sink per output.
- **Output speed:** rated 33 MHz. The fastest protocol output here
  (10BASE-T Manchester) toggles at most at 10 MHz.
- **Input speed:** rated 66 MHz.
- **Pin state when stopped:** every `uio` pin is an input (output enable low)
  after reset, while the engine is stopped, and until a program arms the
  fabric. External pull-ups, not the chip, define idle levels while
  stopped.

## Clock

The demo board's microcontroller generates the project clock (1 Hz to
66.5 MHz). It divides its system clock with PWM/PIO, so pick a system clock
that gives an **integer** divider; fractional dividers add jitter.

| Use | Clock | Why |
| --- | --- | --- |
| Default | 50 MHz | The design target. The first spatial fabric passed signoff at 50 MHz with +3.83 ns slow-corner slack. |
| 10BASE-T | 40 MHz | A half bit is exactly 2 cycles. 802.3 asks for ±100 ppm, so derive it from the crystal-based system clock with an integer divider. |
| USB low speed | 48 MHz (or 50 MHz) | 48 MHz gives exactly 32 cycles per bit. At 50 MHz the programs use 33 cycles (1% fast, inside the ±1.5% LS tolerance). |

UART, SPI, I2C and PS/2 work at any of these; their timer values scale
with the clock.

## Host link (`ui_in`, `uo_out`)

The host link uses all of `ui_in[7:0]` (command bytes) and `uo_out[7:0]`
(responses). The demo board's microcontroller drives it, and the commands
are listed in [architecture.md](architecture.md#host-interface).
The board's alternative uses of these pins (the UART bridge on
`ui_in[3]`/`uo_out[4]`, the gamepad Pmod on `ui_in[4:6]`) are therefore not
available.

- **Hold times:** hold each command byte, and the `8'h00` that must follow
  it, for **at least 2 clocks**. The inputs pass a two-flop synchronizer and
  a byte counts only once it is stable for two cycles, so the host may
  change the pins asynchronously. A byte caught mid-change never acts. A
  MicroPython host is far slower than this anyway.
- **Response time:** a response appears on `uo_out` within 4 clocks of the
  command reaching the pins. SRAM readback (`B`) takes 2 clocks longer.
- **Throughput:** each byte costs two commands. For high-rate output
  (10BASE-T), the program streams frames stored in SRAM instead of
  depending on host speed.

## Protocol pins (`uio`)

Programs can put any protocol on any `uio` pins. The defaults below follow
the Tiny Tapeout recommended pinouts where one exists. The Pmod top row is
`uio[0:3]`, the bottom row `uio[4:7]`.

| Protocol | Default pins | Matches TT pinout | External hardware |
| --- | --- | --- | --- |
| UART 8N1 | `uio[1]` TXD, `uio[2]` RXD | UART top row (CTS/RTS unused) | 3.3 V TTL. Any 3.3 V USB-UART Pmod. RXD needs a defined idle-high level (the adapter, or a pull-up). |
| SPI master | `uio[0]` CS, `uio[1]` MOSI, `uio[2]` MISO, `uio[3]` SCK | SPI top row | Direct to 3.3 V SPI devices; most SPI Pmods match. Tested at 4.2 MHz SCK (50 MHz / 12). |
| I2C master | `uio[2]` SCL, `uio[3]` SDA | I2C top row (INT/RESET unused) | **Pull-ups required** (2.2–4.7 kΩ to 3.3 V) on the Pmod or target: the chip only pulls low (open drain via output enable). 5 V devices need a bidirectional level shifter (PCA9306 or BSS138 type). |
| PS/2 receive | `uio[4]` CLK, `uio[5]` DATA | none (bottom row) | PS/2 devices are 5 V open-collector, so use a **bidirectional level shifter** with pull-ups to 5 V (device side) and 3.3 V (chip side), and supply 5 V to the device. Host-to-device commands are not implemented. |
| USB low speed | `uio[4]` D+, `uio[5]` D− | none (bottom row) | 27–33 Ω series resistors. Device role: 1.5 kΩ pull-up from D− to 3.3 V. Host role: 15 kΩ pull-downs on both lines. 4 mA drive is marginal against cable capacitance, so for more than a short cable add a buffer or a low-speed USB transceiver, plus ESD protection. Packet level only: no turnaround or handshake timing, not USB compliant. |
| 10BASE-T transmit | `uio[6]` TD+, `uio[7]` TD− | none (bottom row) | 40 MHz clock. 4 mA cannot drive the line, so add a **line driver** (fast 3.3 V buffer), a resistor network setting about 2.5 V differential into 100 Ω, and a pulse transformer or an RJ45 jack with integrated magnetics. No waveform pre-distortion and transmit only, so this is hobby-grade, not a compliant PHY. |

Two protocols can share a row only when their pins don't overlap. For
example, UART (`uio[1:2]`) and USB (`uio[4:5]`) can run together.

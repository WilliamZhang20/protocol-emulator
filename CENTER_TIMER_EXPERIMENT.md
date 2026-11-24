# Center-timer physical experiment

This branch is a physical comparison against `9175808`. It moves timer 0 to
the central grid cell and the LUT to its former cell. The attached SPI/UART
component images are rerouted and passed the standalone SRAM-backed fabric
simulation. The shared black-box pin test decodes its baseline fixture routes
and writes equivalent routes for this placement before arming, using only the
host/pin interface. This covers its existing SPI, UART, I2C primitive, JTAG
component and CRC cases; it does not compile complete protocols. The first CI
run used old, unretargeted fixtures and failed on the relocated LUT path.
This branch is a comparison candidate, not yet the selected architecture.

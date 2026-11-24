# Center-timer physical experiment

This branch is a physical comparison against `9175808`. It moves timer 0 to
the central grid cell and the LUT to its former cell. The attached SPI/UART
component images are rerouted and passed the standalone SRAM-backed fabric
simulation. Other pin-level fixtures, especially the hand-routed I2C, JTAG and
CRC examples, have not been adapted to this placement and may fail. Their
failure is not a physical signoff or protocol-coverage claim. The candidate is
not intended to replace the experiment branch until those gaps are addressed.

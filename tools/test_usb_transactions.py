"""Transaction-oracle contracts; these do not establish device RTL support."""

import unittest

from usb_transactions import ACK, DATA0, DATA1, IN, NAK, OUT, SETUP, STALL, Device, crc5, crc16, data_packet, token


class Transactions(unittest.TestCase):
    def test_usb_if_crc_examples(self):
        # USB-IF crcdes.pdf pp5-6, literal expected wire-order bits.
        for field, bits in ((0x15 | 0xE << 7, "10111"), (0x3A | 0xA << 7, "11100"), (0x70 | 4 << 7, "01110")):
            self.assertEqual("".join(str(crc5(field) >> i & 1) for i in range(5)), bits)
        self.assertEqual(crc16(bytes([0, 1, 2, 3])), int("1111011101011110"[::-1], 2))

    def test_in_retry_and_ack(self):
        d = Device(7)
        d.queue_in(b"hello")
        first = d.receive(token(IN, 7, 0))
        d.timeout()
        self.assertEqual(d.receive(token(IN, 7, 0)), first)
        d.receive(bytes([ACK]))
        self.assertEqual(d.in_toggle, 1)
        self.assertEqual(d.receive(token(IN, 7, 0)), bytes([NAK]))
        d.queue_in(b"")
        self.assertEqual(d.receive(token(IN, 7, 0)), data_packet(DATA1, b""))

    def test_out_duplicate_and_backpressure(self):
        d = Device()
        d.receive(token(OUT, 0, 0))
        self.assertEqual(d.receive(data_packet(DATA0, b"a")), bytes([ACK]))
        d.receive(token(OUT, 0, 0))
        self.assertEqual(d.receive(data_packet(DATA0, b"a")), bytes([ACK]))
        self.assertEqual(list(d.received), [(False, b"a")])
        d.receive(token(OUT, 0, 0))
        self.assertEqual(d.receive(data_packet(DATA1, b"b")), bytes([NAK]))
        self.assertEqual(d.out_toggle, 1)
        d.received.popleft()
        d.receive(token(OUT, 0, 0))
        self.assertEqual(d.receive(data_packet(DATA1, b"b")), bytes([ACK]))

    def test_setup_supersedes_and_resets_toggles(self):
        d = Device()
        d.queue_in(b"old")
        d.halted = True
        d.received.append((False, b"old"))
        d.receive(token(SETUP, 0, 0))
        self.assertEqual(d.receive(data_packet(DATA0, bytes(range(8)))), bytes([ACK]))
        self.assertEqual(list(d.received), [(True, bytes(range(8)))])
        self.assertIsNone(d.in_data)
        self.assertFalse(d.halted)
        self.assertEqual((d.in_toggle, d.out_toggle), (1, 1))

    def test_setup_bad_length_pid_crc(self):
        for packet in (data_packet(DATA0, b"short"), data_packet(DATA1, bytes(8)), data_packet(DATA0, bytes(8))[:-1] + b"\0"):
            d = Device()
            d.receive(token(SETUP, 0, 0))
            self.assertIsNone(d.receive(packet))
            self.assertFalse(d.received)

    def test_invalid_token_pid_crc_address_endpoint_and_framing(self):
        d = Device(7)
        good = token(IN, 7, 0)
        for packet in (bytes([good[0] ^ 0x10]) + good[1:], good[:-1] + bytes([good[-1] ^ 0x80]), token(IN, 6, 0), token(IN, 7, 1), good + b"\0"):
            self.assertIsNone(d.receive(packet))
        self.assertIsNone(d.receive(good, framing_valid=False))

    def test_invalid_data_never_commits(self):
        d = Device()
        valid = data_packet(DATA0, b"payload")
        for packet in (valid[:-1] + bytes([valid[-1] ^ 1]), bytes([DATA0 ^ 0x10]) + valid[1:], b"\xc3"):
            d.receive(token(OUT, 0, 0))
            self.assertIsNone(d.receive(packet))
            self.assertFalse(d.received)
            self.assertEqual(d.out_toggle, 0)

    def test_stall_and_unsolicited_ack(self):
        d = Device()
        d.receive(bytes([ACK]))
        self.assertEqual(d.in_toggle, 0)
        d.halted = True
        self.assertEqual(d.receive(token(IN, 0, 0)), bytes([STALL]))
        d.receive(token(OUT, 0, 0))
        self.assertEqual(d.receive(data_packet(DATA0, b"")), bytes([STALL]))

    def test_timeout_cancels_out_and_bad_ack_does_not_release_in(self):
        d = Device()
        d.receive(token(OUT, 0, 0))
        d.timeout()
        self.assertIsNone(d.receive(data_packet(DATA0, b"lost")))
        d.queue_in(b"retry")
        first = d.receive(token(IN, 0, 0))
        d.receive(bytes([ACK ^ 0x10]))
        self.assertEqual(d.receive(token(IN, 0, 0)), first)


if __name__ == "__main__":
    unittest.main()

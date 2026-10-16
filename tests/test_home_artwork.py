from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET


ASSETS = Path(__file__).resolve().parents[1] / "assets"
NS = {"svg": "http://www.w3.org/2000/svg"}


class HomeArtworkTests(unittest.TestCase):
    def test_tv_is_centered_and_sixteen_by_nine(self):
        header = ET.parse(ASSETS / "header.svg").getroot()
        tv = next(rect for rect in header.findall("svg:rect", NS) if rect.get("fill") == "#242a2d")
        width, height = float(tv.get("width")), float(tv.get("height"))
        self.assertEqual(width * 9, height * 16)
        left, top, view_width, view_height = map(float, header.get("viewBox").split())
        self.assertEqual(float(tv.get("x")) + width / 2, left + view_width / 2)
        self.assertEqual(float(tv.get("y")) + height, 380)
        self.assertEqual(top, -50)
        self.assertEqual(view_height, 1000)
        self.assertGreater((float(tv.get("y")) + height - top) / view_height, 0.4)
        self.assertFalse(header.findall(".//svg:text", NS))
        cabinet = next(rect for rect in header.findall("svg:rect", NS) if rect.get("fill") == "#9c704e")
        self.assertLess(float(cabinet.get("width")), width * 1.35)

    def test_mac_mini_keeps_icon_geometry_and_tv_edge_offset(self):
        icon = ET.parse(ASSETS / "icon.svg").getroot()
        header = ET.parse(ASSETS / "header.svg").getroot()
        for color in ["#815b41", "#303638", "#bcc3c8", "#e6e9eb"]:
            source = [node.attrib for node in icon.iter() if node.get("fill") == color]
            expanded = [node.attrib for node in header.iter() if node.get("fill") == color]
            self.assertEqual(source, expanded)
            self.assertTrue(source)
        translated = [node for node in header.iter() if node.get("transform")]
        self.assertEqual(len(translated), 1)
        self.assertEqual(translated[0].get("transform"), "translate(600 0)")
        self.assertEqual((192 + 640 + 600) - (-1520 + 2800), (192 + 640) - 680)

    def test_bundled_render_matches_header_aspect_ratio(self):
        for name in ["header.png", "header-portable.png"]:
            png = (ASSETS / name).read_bytes()
            self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", png[16:24]), (1680, 500))
        self.assertNotEqual((ASSETS / "header.png").read_bytes(),
                            (ASSETS / "header-portable.png").read_bytes())

    def test_portable_ssd_sits_left_of_mac_and_has_cable(self):
        header = ET.parse(ASSETS / "header.svg").getroot()
        ssd = header.find("svg:g[@id='portable-ssd']", NS)
        self.assertEqual(ssd.get("display"), "none")
        body = ssd.find("svg:rect[@fill='#303b43']", NS)
        self.assertLess(float(body.get("x")) + float(body.get("width")), 192 + 600)
        self.assertLessEqual(float(body.get("y")) + float(body.get("height")), 834)
        self.assertIsNotNone(ssd.find("svg:path[@stroke='#202a30']", NS))
        plug = ssd.find("svg:rect[@id='ssd-usb-plug']", NS)
        port = header.find(".//svg:rect[@x='350.5']", NS)
        port_center = float(port.get("x")) + float(port.get("width")) / 2 + 600
        self.assertEqual(float(plug.get("x")) + float(plug.get("width")) / 2, port_center)
        self.assertGreater(float(plug.get("y")), float(port.get("y")))
        self.assertLess(float(plug.get("y")), float(port.get("y")) + float(port.get("height")))
        cable = ssd.find("svg:path[@id='ssd-cable']", NS)
        self.assertTrue(cable.get("d").endswith(f"{port_center:g} 790"))

    def test_emulationstation_banner_preserves_supplied_aspect_ratio(self):
        png = (ASSETS / "tv-menus" / "es-de.png").read_bytes()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", png[16:24])
        self.assertEqual((width, height), (419 * 4, 196 * 4))


if __name__ == "__main__":
    unittest.main()

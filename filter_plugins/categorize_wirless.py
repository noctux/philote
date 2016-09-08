#!/usr/bin/env python2

import unittest
from ansible import errors
 
def categorize_wireless(uciwireless):
    try:
        # Basically, we've got a list with tags. All tags can be reconstructed with the ".name" attribute
        vals = uciwireless.values()
        devs = filter(lambda x: x['.type'] == "wifi-device", vals)
        ifaces = filter(lambda x: x['.type'] == "wifi-iface", vals)

        configs = { "all" : [] }
        for iface in ifaces:
            devname = iface['device']
            dev = uciwireless[devname]
            hwmode = dev['hwmode']
            configs.setdefault(hwmode, [])
            transformed = {
                "device": dev['.name'],
                "htmode": dev['htmode'],
                "hwmode": dev['hwmode'],
                "iface": iface['.name']
            }
            configs[hwmode].append(transformed)
            configs['all'].append(transformed)

        return configs
    except Exception as e:
        raise errors.AnsibleFilterError(
            'categorize_wireless plugin error: {0}, uciwireless={1},'
            ''.format(str(e), str(uciwireless)))
 
class FilterModule(object):
    ''' Categorize wireless nics and the associated aps '''
    def filters(self):
        return {
            'categorize_wireless': categorize_wireless
        }


class TestWirelessFilters(unittest.TestCase):
    def test_categorize_wireless(self):
        testdata = {
            "cfg033579": {
                ".anonymous": True,
                ".index": 1,
                ".name": "cfg033579",
                ".type": "wifi-iface",
                "device": "radio0",
                "encryption": "none",
                "mode": "ap",
                "network": "lan",
                "ssid": "OpenWrt"
            },
            "cfg063579": {
                ".anonymous": True,
                ".index": 3,
                ".name": "cfg063579",
                ".type": "wifi-iface",
                "device": "radio1",
                "encryption": "none",
                "mode": "ap",
                "network": "lan",
                "ssid": "OpenWrt"
            },
            "radio0": {
                ".anonymous": False,
                ".index": 0,
                ".name": "radio0",
                ".type": "wifi-device",
                "channel": "36",
                "disabled": "1",
                "htmode": "VHT80",
                "hwmode": "11a",
                "path": "pci0000:00\/0000:00:00.0\/0000:01:00.0",
                "type": "mac80211"
            },
            "radio1": {
                ".anonymous": False,
                ".index": 2,
                ".name": "radio1",
                ".type": "wifi-device",
                "channel": "11",
                "disabled": "1",
                "htmode": "HT20",
                "hwmode": "11g",
                "path": "pci0000:00\/0000:00:01.0\/0000:02:00.0",
                "type": "mac80211"
            }
        }
        expected = {
            "11a": [{"device" : "radio0", "htmode": "VHT80", "iface": "cfg033579", "hwmode": "11a"}],
            "11g": [{"device" : "radio1", "htmode": "HT20", "iface" : "cfg063579", "hwmode": "11g"}],
            "all": [{"device" : "radio0", "htmode": "VHT80", "iface": "cfg033579", "hwmode": "11a"},
                {"device" : "radio1", "htmode": "HT20", "iface" : "cfg063579", "hwmode": "11g"}]
	}
        self.assertDictEqual(categorize_wireless(testdata), expected)

if __name__ == '__main__':
    unittest.main()

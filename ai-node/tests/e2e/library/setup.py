#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Fact gathering for the simulation: a 256 GiB Apple-silicon Mac on macOS 27.

Shadows ansible.legacy.setup when ANSIBLE_LIBRARY points here, so gather_facts returns the
facts the roles read (system, architecture, distribution_version, memtotal_mb) instead of the
Linux container's.
"""
from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
        argument_spec=dict(
            gather_subset=dict(type="list", default=["all"]),
            gather_timeout=dict(type="int", default=10),
            filter=dict(type="list", default=[]),
            fact_path=dict(type="path", default="/etc/ansible/facts.d"),
            boolean_facts=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    module.exit_json(
        changed=False,
        ansible_facts=dict(
            system="Darwin",
            architecture="arm64",
            machine="arm64",
            distribution="MacOSX",
            distribution_version="27.0",
            distribution_major_version="27",
            distribution_release="25.0.0",
            os_family="Darwin",
            memtotal_mb=262144,
            hostname="sim",
            fqdn="sim.example.com",
        ),
    )


if __name__ == "__main__":
    main()

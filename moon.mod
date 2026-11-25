// serbox — self-hosted, instabox-style Linux boxes on any server, in MoonBit.
//
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "kupas/serbox"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/tomasky/serbox"

license = "Apache-2.0"

keywords = [ "sandbox", "box", "docker", "agent", "linux", "cli" ]

description = "Self-hosted Linux boxes for agents, like instabox but on your own server"

preferred_target = "native"

import {
  "moonbitlang/async@0.22.9",
  "moonbitlang/x@0.5.7",
}

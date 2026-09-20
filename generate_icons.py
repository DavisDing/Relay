import math
import os
import subprocess

# Ensure assets/icons exists
os.makedirs("assets/icons", exist_ok=True)

# 1. OPTION A (Primary Recommended): "The Relay Node / Convergence Nexus"
# A powerful, pure geometric design:
# - Core central relay station (hexagon / circular prism hub with concentric glowing telemetry ring)
# - 3 dynamic curved convergence conduits / bridges sweeping inward with 120-degree symmetry
# - Each conduit originates from an outer terminal satellite node and converges seamlessly into the core hub
# - High-end macOS dark-navy + indigo gradient (#0b1026 -> #1e295d) with vibrant cyan / electric-azure highlights (#38bdf8 -> #06b6d4)
# - Subtly faceted geometric bevels giving physical depth and presence on desktop, yet perfectly solid and recognizable at 16x16.

svg_opt_a = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <!-- Background glow / subtle ambient field -->
    <radialGradient id="ambientGlowA" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.18"/>
      <stop offset="60%" stop-color="#1e1b4b" stop-opacity="0.05"/>
      <stop offset="100%" stop-color="#0f172a" stop-opacity="0"/>
    </radialGradient>

    <!-- Outer Conduit Gradients -->
    <linearGradient id="armGradTop" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#38bdf8"/>
      <stop offset="40%" stop-color="#0284c7"/>
      <stop offset="100%" stop-color="#1e1b4b"/>
    </linearGradient>

    <linearGradient id="armGradBottomRight" x1="100%" y1="100%" x2="0%" y2="0%">
      <stop offset="0%" stop-color="#38bdf8"/>
      <stop offset="40%" stop-color="#2563eb"/>
      <stop offset="100%" stop-color="#0f172a"/>
    </linearGradient>

    <linearGradient id="armGradBottomLeft" x1="0%" y1="100%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#06b6d4"/>
      <stop offset="40%" stop-color="#1d4ed8"/>
      <stop offset="100%" stop-color="#0f172a"/>
    </linearGradient>

    <!-- Outer Satellite Node Gradients -->
    <radialGradient id="nodeGradTop" cx="38%" cy="32%" r="65%">
      <stop offset="0%" stop-color="#e0f2fe"/>
      <stop offset="35%" stop-color="#38bdf8"/>
      <stop offset="75%" stop-color="#0369a1"/>
      <stop offset="100%" stop-color="#0c2340"/>
    </radialGradient>

    <radialGradient id="nodeGradBR" cx="38%" cy="32%" r="65%">
      <stop offset="0%" stop-color="#bae6fd"/>
      <stop offset="35%" stop-color="#0ea5e9"/>
      <stop offset="75%" stop-color="#1d4ed8"/>
      <stop offset="100%" stop-color="#091436"/>
    </radialGradient>

    <radialGradient id="nodeGradBL" cx="38%" cy="32%" r="65%">
      <stop offset="0%" stop-color="#a5f3fc"/>
      <stop offset="35%" stop-color="#06b6d4"/>
      <stop offset="75%" stop-color="#0284c7"/>
      <stop offset="100%" stop-color="#071b38"/>
    </radialGradient>

    <!-- Center Station Outer Ring Gradient -->
    <linearGradient id="hubRingGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#38bdf8"/>
      <stop offset="25%" stop-color="#1e40af"/>
      <stop offset="60%" stop-color="#0f172a"/>
      <stop offset="85%" stop-color="#1e3a8a"/>
      <stop offset="100%" stop-color="#67e8f9"/>
    </linearGradient>

    <!-- Center Core Shield Gradient -->
    <radialGradient id="hubCoreGrad" cx="36%" cy="30%" r="70%">
      <stop offset="0%" stop-color="#2a3875"/>
      <stop offset="45%" stop-color="#131b3e"/>
      <stop offset="85%" stop-color="#090d24"/>
      <stop offset="100%" stop-color="#040612"/>
    </radialGradient>

    <!-- Center Heart Core Glow (Relay Pulse) -->
    <radialGradient id="pulseCoreGrad" cx="40%" cy="35%" r="65%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="25%" stop-color="#bae6fd"/>
      <stop offset="55%" stop-color="#38bdf8"/>
      <stop offset="85%" stop-color="#0284c7"/>
      <stop offset="100%" stop-color="#0369a1"/>
    </radialGradient>

    <!-- Center Bevel Highlight -->
    <linearGradient id="bevelLight" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.6"/>
      <stop offset="50%" stop-color="#38bdf8" stop-opacity="0.1"/>
      <stop offset="100%" stop-color="#000000" stop-opacity="0.4"/>
    </linearGradient>

    <!-- Drop Shadows for Physical Desktop App Feel -->
    <filter id="hubShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#020617" flood-opacity="0.65"/>
    </filter>

    <filter id="glowSubtle" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="10" result="blur"/>
      <feComposite in="SourceGraphic" in2="blur" operator="over"/>
    </filter>
  </defs>

  <!-- Ambient Convergence Glow -->
  <circle cx="512" cy="512" r="460" fill="url(#ambientGlowA)" />

  <!-- Outer Interconnection Orbit Ring (Subtle Track) -->
  <circle cx="512" cy="512" r="325" fill="none" stroke="#1e293b" stroke-width="12" stroke-dasharray="14 18" stroke-opacity="0.45" />
  <circle cx="512" cy="512" r="325" fill="none" stroke="#38bdf8" stroke-width="4" stroke-opacity="0.3" />

  <!-- 3 Curved Conduit Arms Converging to Central Relay (120-deg rotational symmetry) -->
  <!-- Conduit 1: North (Top) -->
  <g id="conduitNorth">
    <!-- Path from outer top node (512, 188) to center hub -->
    <path d="M 482 188
             C 482 320, 470 380, 440 450
             L 512 430
             L 584 450
             C 554 380, 542 320, 542 188
             Z"
          fill="url(#armGradTop)" />
    <!-- Center energy waveguide beam -->
    <path d="M 512 188 L 512 445" stroke="#bae6fd" stroke-width="10" stroke-linecap="round" opacity="0.85"/>
  </g>

  <!-- Conduit 2: South-East (rotated 120 deg around 512, 512) -->
  <g id="conduitSE" transform="rotate(120 512 512)">
    <path d="M 482 188
             C 482 320, 470 380, 440 450
             L 512 430
             L 584 450
             C 554 380, 542 320, 542 188
             Z"
          fill="url(#armGradBottomRight)" />
    <path d="M 512 188 L 512 445" stroke="#7dd3fc" stroke-width="10" stroke-linecap="round" opacity="0.85"/>
  </g>

  <!-- Conduit 3: South-West (rotated 240 deg around 512, 512) -->
  <g id="conduitSW" transform="rotate(240 512 512)">
    <path d="M 482 188
             C 482 320, 470 380, 440 450
             L 512 430
             L 584 450
             C 554 380, 542 320, 542 188
             Z"
          fill="url(#armGradBottomLeft)" />
    <path d="M 512 188 L 512 445" stroke="#67e8f9" stroke-width="10" stroke-linecap="round" opacity="0.85"/>
  </g>

  <!-- Outer Satellite Nodes (Relay endpoints) -->
  <!-- Node 1: Top (512, 188) -->
  <g id="nodeNorth" filter="url(#hubShadow)">
    <circle cx="512" cy="188" r="64" fill="url(#nodeGradTop)" />
    <circle cx="512" cy="188" r="63" fill="none" stroke="url(#bevelLight)" stroke-width="3" />
    <circle cx="512" cy="188" r="24" fill="#ffffff" opacity="0.95" />
    <circle cx="512" cy="188" r="14" fill="#38bdf8" />
  </g>

  <!-- Node 2: Bottom-Right (rotated 120 from North -> (793, 674)) -->
  <g id="nodeSE" filter="url(#hubShadow)">
    <circle cx="793.4" cy="674.5" r="64" fill="url(#nodeGradBR)" />
    <circle cx="793.4" cy="674.5" r="63" fill="none" stroke="url(#bevelLight)" stroke-width="3" />
    <circle cx="793.4" cy="674.5" r="24" fill="#ffffff" opacity="0.95" />
    <circle cx="793.4" cy="674.5" r="14" fill="#0284c7" />
  </g>

  <!-- Node 3: Bottom-Left (rotated 240 from North -> (230.6, 674.5)) -->
  <g id="nodeSW" filter="url(#hubShadow)">
    <circle cx="230.6" cy="674.5" r="64" fill="url(#nodeGradBL)" />
    <circle cx="230.6" cy="674.5" r="63" fill="none" stroke="url(#bevelLight)" stroke-width="3" />
    <circle cx="230.6" cy="674.5" r="24" fill="#ffffff" opacity="0.95" />
    <circle cx="230.6" cy="674.5" r="14" fill="#06b6d4" />
  </g>

  <!-- Main Central Relay Hub (Master Station) -->
  <g id="centralHub" filter="url(#hubShadow)">
    <!-- Outer Heavy Chassis Bezel (Hex-rounded / circular precision housing) -->
    <circle cx="512" cy="512" r="204" fill="url(#hubRingGrad)" />
    <!-- Outer rim highlight -->
    <circle cx="512" cy="512" r="203" fill="none" stroke="url(#bevelLight)" stroke-width="4" />
    <circle cx="512" cy="512" r="176" fill="#0b0f24" />

    <!-- Recessed Inner Platform -->
    <circle cx="512" cy="512" r="162" fill="url(#hubCoreGrad)" />
    
    <!-- Precision Graduation Ring (Relay Alignment Ticks) -->
    <circle cx="512" cy="512" r="142" fill="none" stroke="#38bdf8" stroke-width="8" stroke-dasharray="8 20" opacity="0.6" />
    
    <!-- Concentric Inner Telemetry Track -->
    <circle cx="512" cy="512" r="114" fill="none" stroke="#1d4ed8" stroke-width="12" opacity="0.75" />
    <circle cx="512" cy="512" r="114" fill="none" stroke="#67e8f9" stroke-width="5" stroke-dasharray="40 80" opacity="0.9" />

    <!-- Central High-Intensity Core (The Relay Heart) -->
    <circle cx="512" cy="512" r="76" fill="url(#pulseCoreGrad)" />
    <circle cx="512" cy="512" r="75" fill="none" stroke="#ffffff" stroke-width="3" opacity="0.7" />

    <!-- Core Focal Iris / Solid geometric anchor for micro size (16px) visibility -->
    <circle cx="512" cy="512" r="36" fill="#ffffff" />
    <circle cx="512" cy="512" r="20" fill="#0369a1" />
  </g>

  <!-- Polished Glass Specular Arc / Subtle Native macOS Reflection -->
  <path d="M 372 400
           C 410 350, 460 326, 512 326
           C 564 326, 614 350, 652 400
           C 592 374, 532 362, 512 362
           C 472 362, 420 374, 372 400 Z"
        fill="#ffffff" opacity="0.32" />
</svg>
"""

# 2. OPTION B: "The Quad-Bridge / Cross-Relay Monolith"
# Structure: 4 orthogonal & diagonal cross-relays with an interlocking precision ring
# Geometry: 4 service conduits converging symmetrically from Cardinal directions (N, E, S, W)
# Feel: Deep enterprise reliability, network switchboard, bridge between disparate clouds
svg_opt_b = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="ambientGlowB" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.16"/>
      <stop offset="70%" stop-color="#1e1b4b" stop-opacity="0.04"/>
      <stop offset="100%" stop-color="#020617" stop-opacity="0"/>
    </radialGradient>

    <linearGradient id="chassisGradB" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#1e293b"/>
      <stop offset="40%" stop-color="#0f172a"/>
      <stop offset="100%" stop-color="#020617"/>
    </linearGradient>

    <linearGradient id="bridgeVert" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#38bdf8"/>
      <stop offset="50%" stop-color="#1d4ed8"/>
      <stop offset="100%" stop-color="#0284c7"/>
    </linearGradient>

    <linearGradient id="bridgeHoriz" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#06b6d4"/>
      <stop offset="50%" stop-color="#2563eb"/>
      <stop offset="100%" stop-color="#38bdf8"/>
    </linearGradient>

    <radialGradient id="coreRelayB" cx="35%" cy="30%" r="65%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="20%" stop-color="#7dd3fc"/>
      <stop offset="55%" stop-color="#0284c7"/>
      <stop offset="90%" stop-color="#0f172a"/>
      <stop offset="100%" stop-color="#020617"/>
    </radialGradient>

    <linearGradient id="rimB" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#bae6fd" stop-opacity="0.7"/>
      <stop offset="100%" stop-color="#0f172a" stop-opacity="0.2"/>
    </linearGradient>

    <filter id="shadowB" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#020617" flood-opacity="0.6"/>
    </filter>
  </defs>

  <circle cx="512" cy="512" r="460" fill="url(#ambientGlowB)" />

  <!-- Outer Orbit Band -->
  <circle cx="512" cy="512" r="340" fill="none" stroke="#1e293b" stroke-width="20" stroke-dasharray="24 32" opacity="0.6" />
  <circle cx="512" cy="512" r="340" fill="none" stroke="#0ea5e9" stroke-width="4" opacity="0.4" />

  <!-- 4 Primary Conduits (Cross) -->
  <g filter="url(#shadowB)">
    <!-- Vertical Conduit -->
    <path d="M 464 160 L 560 160 L 550 864 L 474 864 Z" fill="url(#bridgeVert)" rx="28"/>
    <!-- Horizontal Conduit -->
    <path d="M 160 464 L 864 464 L 864 560 L 160 560 Z" fill="url(#bridgeHoriz)" rx="28"/>
  </g>

  <!-- 4 Terminal Hubs on Cross Ends -->
  <g id="nodesCross">
    <!-- North -->
    <circle cx="512" cy="180" r="54" fill="#0f172a" stroke="#38bdf8" stroke-width="10"/>
    <circle cx="512" cy="180" r="22" fill="#e0f2fe"/>
    <!-- South -->
    <circle cx="512" cy="844" r="54" fill="#0f172a" stroke="#0284c7" stroke-width="10"/>
    <circle cx="512" cy="844" r="22" fill="#7dd3fc"/>
    <!-- West -->
    <circle cx="180" cy="512" r="54" fill="#0f172a" stroke="#06b6d4" stroke-width="10"/>
    <circle cx="180" cy="512" r="22" fill="#a5f3fc"/>
    <!-- East -->
    <circle cx="844" cy="512" r="54" fill="#0f172a" stroke="#38bdf8" stroke-width="10"/>
    <circle cx="844" cy="512" r="22" fill="#e0f2fe"/>
  </g>

  <!-- Central Interlocking Torus Ring -->
  <g filter="url(#shadowB)">
    <circle cx="512" cy="512" r="220" fill="url(#chassisGradB)" stroke="url(#rimB)" stroke-width="8"/>
    <circle cx="512" cy="512" r="180" fill="none" stroke="#38bdf8" stroke-width="16" stroke-dasharray="60 30" />
    <circle cx="512" cy="512" r="140" fill="#090d21" />

    <!-- Center Convergence Nucleus -->
    <circle cx="512" cy="512" r="96" fill="url(#coreRelayB)" />
    <circle cx="512" cy="512" r="44" fill="#ffffff" />
    <circle cx="512" cy="512" r="24" fill="#0284c7" />
  </g>
</svg>
"""

# 3. OPTION C: "The Kinetic R-Relay / Orbital Data Prism"
# Structure: An abstract, refined typographic and geometric tribute to "R" (Relay) blended with orbital tracking loops
# Geometry: Two sweeping orbital rings that converge into a central vertical mast / relay spine, evoking the letter 'R' organically without literal letters
# Feel: Agile, high-velocity sync, lightweight macOS utility
svg_opt_c = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="ambientGlowC" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.18"/>
      <stop offset="70%" stop-color="#1e1b4b" stop-opacity="0.05"/>
      <stop offset="100%" stop-color="#020617" stop-opacity="0"/>
    </radialGradient>

    <linearGradient id="mastGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#e0f2fe"/>
      <stop offset="25%" stop-color="#38bdf8"/>
      <stop offset="70%" stop-color="#1d4ed8"/>
      <stop offset="100%" stop-color="#0f172a"/>
    </linearGradient>

    <linearGradient id="loopGradTop" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#67e8f9"/>
      <stop offset="40%" stop-color="#0ea5e9"/>
      <stop offset="80%" stop-color="#1e40af"/>
      <stop offset="100%" stop-color="#0f172a"/>
    </linearGradient>

    <linearGradient id="legGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#0ea5e9"/>
      <stop offset="50%" stop-color="#2563eb"/>
      <stop offset="100%" stop-color="#0284c7"/>
    </linearGradient>

    <filter id="shadowC" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="16" stdDeviation="22" flood-color="#020617" flood-opacity="0.6"/>
    </filter>
  </defs>

  <circle cx="512" cy="512" r="460" fill="url(#ambientGlowC)" />

  <!-- Outer Telemetry Halo -->
  <circle cx="512" cy="512" r="340" fill="none" stroke="#1e293b" stroke-width="10" stroke-dasharray="16 24" opacity="0.45" />

  <g filter="url(#shadowC)">
    <!-- Vertical Anchor Mast (Station Spine) -->
    <rect x="300" y="180" width="110" height="664" rx="55" fill="url(#mastGrad)"/>
    <circle cx="355" cy="235" r="32" fill="#ffffff"/>
    <circle cx="355" cy="789" r="28" fill="#38bdf8"/>

    <!-- Upper Convergence Loop (Arch of R) -->
    <path d="M 380 200
             C 560 200, 720 250, 720 400
             C 720 530, 580 580, 410 580
             L 410 470
             C 520 470, 600 440, 600 395
             C 600 340, 500 310, 380 310 Z"
          fill="url(#loopGradTop)"/>

    <!-- Diagonal Data Conduit (Leg of R) -->
    <path d="M 440 520
             L 690 820
             C 715 850, 755 850, 780 825
             C 805 800, 805 760, 775 730
             L 535 450 Z"
          fill="url(#legGrad)"/>

    <!-- Central Telemetry Station Focal Point -->
    <circle cx="550" cy="400" r="44" fill="#0c183a" stroke="#38bdf8" stroke-width="8"/>
    <circle cx="550" cy="400" r="20" fill="#ffffff"/>
  </g>
</svg>
"""

with open("assets/icons/Relay-AppIcon-OptionA.svg", "w") as f:
    f.write(svg_opt_a.strip())

with open("assets/icons/Relay-AppIcon-OptionB.svg", "w") as f:
    f.write(svg_opt_b.strip())

with open("assets/icons/Relay-AppIcon-OptionC.svg", "w") as f:
    f.write(svg_opt_c.strip())

# The user specifically requested:
# "文件：Relay-AppIcon-1024.png"
# "同时尽量提供一份可编辑 SVG 源文件"
with open("assets/icons/Relay-AppIcon.svg", "w") as f:
    f.write(svg_opt_a.strip())

print("SVGs written successfully.")

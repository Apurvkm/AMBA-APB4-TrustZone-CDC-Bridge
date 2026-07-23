Asynchronous AMBA APB4 CDC Bridge with TrustZone Firewall

Overview

A dual-clock domain RTL design serving as a bridge between a high-speed system processor (100 MHz) and a slower peripheral bus (40 MHz). This project implements the AMBA APB4 protocol and includes a hardware-level TrustZone firewall to drop unauthorized non-secure transactions.

Key Architectural Features:

Clock Domain Crossing (CDC): Utilizes an Asynchronous FIFO parameterized with Gray-code pointer synchronization to eliminate metastability across clock boundaries.

Hardware Firewall: Enforces APB4 PPROT (Protection) signals. Transactions attempting to access secure memory regions from a non-secure state are dynamically blocked, returning a PSLVERR (Slave Error).

Protocol FSM: 3-state APB Master FSM (IDLE, SETUP, ACCESS) strictly enforcing AMBA timing handshakes.

Verification Strategy & Metrics

The design was verified using a Layered Object-Oriented Testbench (OOP) to isolate transaction generation from physical pin driving.

Simulator: Cadence Xcelium

Strategy: Constrained Random Generation

Functional Coverage: Achieved 100.00% coverage across cross-coverage bins including Operations (Read/Write), Security States (Secure/Non-Secure), and Firewall Responses (Granted/Blocked).

Coverage Report

<img width="600" height="500" alt="image" src="https://github.com/user-attachments/assets/9fbecc6e-552e-4ade-8b8a-2f512f41238b" />


Waveform Analysis

The waveform below demonstrates the FSM successfully popping a randomized transaction from the CDC FIFO, initiating the SETUP and ACCESS phases on the 40MHz clock, and the TrustZone Firewall successfully triggering a Slave Error (pslverr = 1) on a blocked non-secure transaction.

<img width="600" height="308" alt="image" src="https://github.com/user-attachments/assets/14586a1c-e102-4110-b01e-6808bcfd7720" />

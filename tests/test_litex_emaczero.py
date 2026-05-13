# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design

import importlib
import sys
import types
from pathlib import Path


class _Signal:
    def __init__(self, width=1):
        self.width = width

    def __getitem__(self, key):
        return self

    def __invert__(self):
        return self


class _Specials(list):
    def __iadd__(self, item):
        self.append(item)
        return self


class _LiteXModule:
    @property
    def specials(self):
        if not hasattr(self, "_specials"):
            self._specials = _Specials()
        return self._specials

    @specials.setter
    def specials(self, value):
        self._specials = value


class _TSTriple:
    def __init__(self, width=1):
        self.o = _Signal(width)
        self.oe = _Signal()
        self.i = _Signal(width)


class _Channel:
    def __init__(self):
        self.addr = _Signal(8)
        self.valid = _Signal()
        self.ready = _Signal()
        self.data = _Signal(32)
        self.strb = _Signal(4)
        self.resp = _Signal(2)


class _AXILiteInterface:
    def __init__(self, data_width, address_width):
        self.aw = _Channel()
        self.w = _Channel()
        self.b = _Channel()
        self.ar = _Channel()
        self.r = _Channel()


class _Endpoint:
    def __init__(self, layout):
        self.valid = _Signal()
        self.ready = _Signal()
        self.first = _Signal()
        self.last = _Signal()
        for name, width in layout:
            setattr(self, name, _Signal(width))


class _Platform:
    def __init__(self):
        self.sources = []

    def add_source(self, path):
        self.sources.append(path)


class _Pads:
    tx_data = _Signal(4)
    tx_en = _Signal()
    tx_clk = _Signal()
    rx_data = _Signal(4)
    rx_dv = _Signal()
    rx_er = _Signal()
    rx_clk = _Signal()
    mdc = _Signal()


def test_litex_wrapper_imports_and_instantiates_without_include_path(monkeypatch):
    assert not (Path(__file__).resolve().parents[1] / "litex").exists()

    migen = types.ModuleType("migen")
    migen.ClockSignal = lambda name=None: _Signal()
    migen.Instance = lambda name, **kwargs: (name, kwargs)
    migen.Module = object
    migen.ResetSignal = lambda name=None: _Signal()
    migen.Signal = _Signal
    migen.TSTriple = _TSTriple

    litex = types.ModuleType("litex")
    gen = types.ModuleType("litex.gen")
    gen.LiteXModule = _LiteXModule
    interconnect = types.ModuleType("litex.soc.interconnect")
    axi = types.ModuleType("litex.soc.interconnect.axi")
    axi.AXILiteInterface = _AXILiteInterface
    stream = types.ModuleType("litex.soc.interconnect.stream")
    stream.Endpoint = _Endpoint

    monkeypatch.setitem(sys.modules, "migen", migen)
    monkeypatch.setitem(sys.modules, "litex", litex)
    monkeypatch.setitem(sys.modules, "litex.gen", gen)
    monkeypatch.setitem(sys.modules, "litex.soc", types.ModuleType("litex.soc"))
    monkeypatch.setitem(sys.modules, "litex.soc.interconnect", interconnect)
    monkeypatch.setitem(sys.modules, "litex.soc.interconnect.axi", axi)
    monkeypatch.setitem(sys.modules, "litex.soc.interconnect.stream", stream)
    monkeypatch.delitem(sys.modules, "litex_emaczero", raising=False)
    monkeypatch.delitem(sys.modules, "litex_emaczero.emaczero", raising=False)

    module = importlib.import_module("litex_emaczero")
    mac = module.EmacZero(_Platform(), _Pads())

    assert hasattr(mac.source, "first")

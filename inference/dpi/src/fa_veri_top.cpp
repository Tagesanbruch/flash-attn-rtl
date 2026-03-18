#include "fa_veri_top.hpp"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>

#ifndef FA_DPI_USE_VERILATOR
#error "src/fa_veri_top.cpp is RTL-backed and requires FA_DPI_USE_VERILATOR=1. Use stub_src for stub backend."
#endif

#include "Vfa_attention_ip_top.h"
#include "verilated.h"

namespace fa::dpi {

static vluint64_t g_dpi_sim_time = 0;

} // namespace fa::dpi

double sc_time_stamp() {
  return static_cast<double>(fa::dpi::g_dpi_sim_time);
}

namespace fa::dpi {

namespace {

constexpr uint32_t kAxiBeatBytes = 16;

struct ReadTxn {
  uint32_t addr = 0;
  uint32_t beats = 0;
  uint32_t idx = 0;
  bool active = false;
};

struct WriteTxn {
  uint32_t addr = 0;
  uint32_t beats = 0;
  uint32_t idx = 0;
  bool active = false;
  bool bvalid_pending = false;
};

static inline uint8_t get_byte_from_u32x4(const uint32_t words[4], int byte_idx) {
  const int word = byte_idx / 4;
  const int shift = (byte_idx % 4) * 8;
  return static_cast<uint8_t>((words[word] >> shift) & 0xFFu);
}

static inline void set_byte_to_u32x4(uint32_t words[4], int byte_idx, uint8_t value) {
  const int word = byte_idx / 4;
  const int shift = (byte_idx % 4) * 8;
  words[word] &= ~(0xFFu << shift);
  words[word] |= (static_cast<uint32_t>(value) << shift);
}

} // namespace

struct FaVeriTop::Impl {
  fa_dpi_init_cfg_t cfg{};
  bool inited = false;

  std::unique_ptr<FaDmaMemModel> mem;
  std::unique_ptr<Vfa_attention_ip_top> dut;
  uint64_t sim_time = 0;

  ReadTxn rd;
  WriteTxn wr;

  void reset_dut() {
    dut->rst_n = 0;
    for (int i = 0; i < 10; i++) {
      step_once();
    }
    dut->rst_n = 1;
    for (int i = 0; i < 10; i++) {
      step_once();
    }
  }

  void init_ports() {
    dut->clk = 0;

    dut->s_axil_awaddr = 0;
    dut->s_axil_awvalid = 0;
    dut->s_axil_wdata = 0;
    dut->s_axil_wstrb = 0xF;
    dut->s_axil_wvalid = 0;
    dut->s_axil_bready = 0;
    dut->s_axil_araddr = 0;
    dut->s_axil_arvalid = 0;
    dut->s_axil_rready = 0;

    dut->m_axi_arready = 1;
    dut->m_axi_rid = 0;
    dut->m_axi_rresp = 0;
    dut->m_axi_rlast = 0;
    dut->m_axi_rvalid = 0;
    dut->m_axi_rdata[0] = 0;
    dut->m_axi_rdata[1] = 0;
    dut->m_axi_rdata[2] = 0;
    dut->m_axi_rdata[3] = 0;

    dut->m_axi_awready = 1;
    dut->m_axi_wready = 1;
    dut->m_axi_bid = 0;
    dut->m_axi_bresp = 0;
    dut->m_axi_bvalid = 0;
  }

  bool mem_load_beat(uint32_t addr, uint32_t out_words[4]) const {
    return mem->read(addr, out_words, kAxiBeatBytes);
  }

  bool mem_store_beat(uint32_t addr, const uint32_t in_words[4], uint16_t wstrb) {
    uint8_t bytes[kAxiBeatBytes] = {0};
    if (!mem->read(addr, bytes, kAxiBeatBytes)) {
      return false;
    }

    for (int i = 0; i < static_cast<int>(kAxiBeatBytes); i++) {
      if ((wstrb >> i) & 0x1) {
        bytes[i] = get_byte_from_u32x4(in_words, i);
      }
    }

    return mem->write(addr, bytes, kAxiBeatBytes);
  }

  void drive_memory_responses() {
    dut->m_axi_arready = 1;
    dut->m_axi_awready = 1;
    dut->m_axi_wready = 1;

    if (rd.active) {
      uint32_t words[4] = {0, 0, 0, 0};
      const uint32_t beat_addr = rd.addr + rd.idx * kAxiBeatBytes;
      mem_load_beat(beat_addr, words);
      dut->m_axi_rvalid = 1;
      dut->m_axi_rlast = (rd.idx + 1 == rd.beats) ? 1 : 0;
      dut->m_axi_rdata[0] = words[0];
      dut->m_axi_rdata[1] = words[1];
      dut->m_axi_rdata[2] = words[2];
      dut->m_axi_rdata[3] = words[3];
      dut->m_axi_rresp = 0;
      dut->m_axi_rid = dut->m_axi_arid;
    } else {
      dut->m_axi_rvalid = 0;
      dut->m_axi_rlast = 0;
      dut->m_axi_rdata[0] = 0;
      dut->m_axi_rdata[1] = 0;
      dut->m_axi_rdata[2] = 0;
      dut->m_axi_rdata[3] = 0;
      dut->m_axi_rresp = 0;
      dut->m_axi_rid = 0;
    }

    dut->m_axi_bvalid = wr.bvalid_pending ? 1 : 0;
    dut->m_axi_bresp = 0;
    dut->m_axi_bid = dut->m_axi_awid;
  }

  void step_once() {
    drive_memory_responses();

    dut->clk = 0;
    dut->eval();

    if (!rd.active && dut->m_axi_arvalid && dut->m_axi_arready) {
      rd.addr = static_cast<uint32_t>(dut->m_axi_araddr);
      rd.beats = static_cast<uint32_t>(dut->m_axi_arlen) + 1u;
      rd.idx = 0;
      rd.active = true;
    }

    if (!wr.active && dut->m_axi_awvalid && dut->m_axi_awready) {
      wr.addr = static_cast<uint32_t>(dut->m_axi_awaddr);
      wr.beats = static_cast<uint32_t>(dut->m_axi_awlen) + 1u;
      wr.idx = 0;
      wr.active = true;
      wr.bvalid_pending = false;
    }

    if (wr.active && dut->m_axi_wvalid && dut->m_axi_wready) {
      uint32_t words[4] = {
          static_cast<uint32_t>(dut->m_axi_wdata[0]),
          static_cast<uint32_t>(dut->m_axi_wdata[1]),
          static_cast<uint32_t>(dut->m_axi_wdata[2]),
          static_cast<uint32_t>(dut->m_axi_wdata[3]),
      };
      const uint16_t wstrb = static_cast<uint16_t>(dut->m_axi_wstrb);
      const uint32_t beat_addr = wr.addr + wr.idx * kAxiBeatBytes;
      mem_store_beat(beat_addr, words, wstrb);

      wr.idx++;
      if (dut->m_axi_wlast || wr.idx >= wr.beats) {
        wr.active = false;
        wr.bvalid_pending = true;
      }
    }

    dut->clk = 1;
    dut->eval();
    sim_time++;
    g_dpi_sim_time = sim_time;

    if (rd.active && dut->m_axi_rvalid && dut->m_axi_rready) {
      rd.idx++;
      if (rd.idx >= rd.beats) {
        rd.active = false;
      }
    }

    if (wr.bvalid_pending && dut->m_axi_bvalid && dut->m_axi_bready) {
      wr.bvalid_pending = false;
    }
  }

  bool axil_write(uint32_t addr, uint32_t data) {
    dut->s_axil_awaddr = addr;
    dut->s_axil_awvalid = 1;
    dut->s_axil_wdata = data;
    dut->s_axil_wstrb = 0xF;
    dut->s_axil_wvalid = 1;
    dut->s_axil_bready = 0;

    bool aw_done = false;
    bool w_done = false;

    bool b_done = false;
    dut->s_axil_bready = 1;
    for (int i = 0; i < 20000; i++) {
      step_once();
      if (!aw_done && dut->s_axil_awready) {
        dut->s_axil_awvalid = 0;
        aw_done = true;
      }
      if (!w_done && dut->s_axil_wready) {
        dut->s_axil_wvalid = 0;
        w_done = true;
      }
      if (dut->s_axil_bvalid) {
        b_done = true;
        break;
      }
    }
    dut->s_axil_bready = 0;

    return b_done;
  }

  bool axil_read(uint32_t addr, uint32_t &data) {
    dut->s_axil_araddr = addr;
    dut->s_axil_arvalid = 1;
    dut->s_axil_rready = 0;

    const bool debug_axil = (std::getenv("FA_DPI_DEBUG_AXIL") != nullptr);
    for (int i = 0; i < 20000; i++) {
      step_once();
      if (dut->s_axil_arready) {
        dut->s_axil_arvalid = 0;
      }
      if (debug_axil && i < 16) {
        std::fprintf(stderr,
                     "[fa_dpi][axil_read] i=%d addr=0x%08x arready=%u arvalid=%u rvalid=%u rready=%u rdata=0x%08x\n",
                     i, addr, (unsigned)dut->s_axil_arready,
                     (unsigned)dut->s_axil_arvalid,
                     (unsigned)dut->s_axil_rvalid,
                     (unsigned)dut->s_axil_rready,
                     (unsigned)dut->s_axil_rdata);
      }
      if (dut->s_axil_rvalid) {
        data = static_cast<uint32_t>(dut->s_axil_rdata);
        dut->s_axil_arvalid = 0;
        dut->s_axil_rready = 0;
        return true;
      }
    }
    dut->s_axil_rready = 0;
    dut->s_axil_arvalid = 0;
    return false;
  }
};

FaVeriTop::FaVeriTop() : impl_(std::make_unique<Impl>()) {}
FaVeriTop::~FaVeriTop() { shutdown(); }

bool FaVeriTop::init(const fa_dpi_init_cfg_t &cfg) {
  if (impl_->inited) {
    return true;
  }

  const uint32_t mem_bytes = cfg.memory_bytes == 0 ? (64u * 1024u * 1024u) : cfg.memory_bytes;
  impl_->cfg = cfg;
  impl_->mem = std::make_unique<FaDmaMemModel>(mem_bytes);
  impl_->dut = std::make_unique<Vfa_attention_ip_top>();
  impl_->init_ports();
  impl_->reset_dut();
  impl_->inited = true;
  return true;
}

void FaVeriTop::shutdown() {
  if (!impl_->inited) {
    return;
  }
  impl_->dut.reset();
  impl_->mem.reset();
  impl_->inited = false;
}

bool FaVeriTop::axil_write(uint32_t addr, uint32_t data) {
  if (!impl_->inited) {
    return false;
  }
  return impl_->axil_write(addr, data);
}

bool FaVeriTop::axil_read(uint32_t addr, uint32_t &data) {
  if (!impl_->inited) {
    return false;
  }
  return impl_->axil_read(addr, data);
}

void FaVeriTop::tick(uint32_t cycles) {
  if (!impl_->inited) {
    return;
  }
  for (uint32_t i = 0; i < cycles; i++) {
    impl_->step_once();
  }
}

bool FaVeriTop::mem_write(uint64_t addr, const void *src, uint32_t bytes) {
  if (!impl_->inited || !impl_->mem) {
    return false;
  }
  return impl_->mem->write(addr, src, bytes);
}

bool FaVeriTop::mem_read(uint64_t addr, void *dst, uint32_t bytes) const {
  if (!impl_->inited || !impl_->mem) {
    return false;
  }
  return impl_->mem->read(addr, dst, bytes);
}

} // namespace fa::dpi

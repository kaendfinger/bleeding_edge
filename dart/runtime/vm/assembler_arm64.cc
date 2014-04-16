// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/globals.h"
#if defined(TARGET_ARCH_ARM64)

#include "vm/assembler.h"
#include "vm/cpu.h"
#include "vm/longjump.h"
#include "vm/runtime_entry.h"
#include "vm/simulator.h"
#include "vm/stack_frame.h"
#include "vm/stub_code.h"

// An extra check since we are assuming the existence of /proc/cpuinfo below.
#if !defined(USING_SIMULATOR) && !defined(__linux__) && !defined(ANDROID)
#error ARM64 cross-compile only supported on Linux
#endif

namespace dart {

DEFINE_FLAG(bool, print_stop_message, true, "Print stop message.");
DECLARE_FLAG(bool, inline_alloc);


Assembler::Assembler(bool use_far_branches)
    : buffer_(),
      object_pool_(GrowableObjectArray::Handle()),
      patchable_pool_entries_(),
      prologue_offset_(-1),
      use_far_branches_(use_far_branches),
      comments_() {
  if (Isolate::Current() != Dart::vm_isolate()) {
    object_pool_ = GrowableObjectArray::New(Heap::kOld);

    // These objects and labels need to be accessible through every pool-pointer
    // at the same index.
    object_pool_.Add(Object::null_object(), Heap::kOld);
    patchable_pool_entries_.Add(kNotPatchable);
    // Not adding Object::null() to the index table. It is at index 0 in the
    // object pool, but the HashMap uses 0 to indicate not found.

    object_pool_.Add(Bool::True(), Heap::kOld);
    patchable_pool_entries_.Add(kNotPatchable);
    object_pool_index_table_.Insert(ObjIndexPair(Bool::True().raw(), 1));

    object_pool_.Add(Bool::False(), Heap::kOld);
    patchable_pool_entries_.Add(kNotPatchable);
    object_pool_index_table_.Insert(ObjIndexPair(Bool::False().raw(), 2));
  }
}


void Assembler::InitializeMemoryWithBreakpoints(uword data, intptr_t length) {
  ASSERT(Utils::IsAligned(data, 4));
  ASSERT(Utils::IsAligned(length, 4));
  const uword end = data + length;
  while (data < end) {
    *reinterpret_cast<int32_t*>(data) = Instr::kBreakPointInstruction;
    data += 4;
  }
}


void Assembler::Stop(const char* message) {
  UNIMPLEMENTED();
}


void Assembler::Emit(int32_t value) {
  AssemblerBuffer::EnsureCapacity ensured(&buffer_);
  buffer_.Emit<int32_t>(value);
}


static const char* cpu_reg_names[kNumberOfCpuRegisters] = {
  "r0",  "r1",  "r2",  "r3",  "r4",  "r5",  "r6",  "r7",
  "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
  "r16", "r17", "r18", "r19", "r20", "r21", "r22", "r23",
  "r24", "ip0", "ip1", "pp",  "ctx", "fp",  "lr",  "r31",
};


const char* Assembler::RegisterName(Register reg) {
  ASSERT((0 <= reg) && (reg < kNumberOfCpuRegisters));
  return cpu_reg_names[reg];
}


static const char* fpu_reg_names[kNumberOfFpuRegisters] = {
  "v0",  "v1",  "v2",  "v3",  "v4",  "v5",  "v6",  "v7",
  "v8",  "v9",  "v10", "v11", "v12", "v13", "v14", "v15",
  "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
  "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
};


const char* Assembler::FpuRegisterName(FpuRegister reg) {
  ASSERT((0 <= reg) && (reg < kNumberOfFpuRegisters));
  return fpu_reg_names[reg];
}


// TODO(zra): Support for far branches. Requires loading large immediates.
void Assembler::Bind(Label* label) {
  ASSERT(!label->IsBound());
  intptr_t bound_pc = buffer_.Size();

  while (label->IsLinked()) {
    const int64_t position = label->Position();
    const int64_t dest = bound_pc - position;
    const int32_t next = buffer_.Load<int32_t>(position);
    const int32_t encoded = EncodeImm19BranchOffset(dest, next);
    buffer_.Store<int32_t>(position, encoded);
    label->position_ = DecodeImm19BranchOffset(next);
  }
  label->BindTo(bound_pc);
}


static int CountLeadingZeros(uint64_t value, int width) {
  ASSERT((width == 32) || (width == 64));
  if (value == 0) {
    return width;
  }
  int count = 0;
  do {
    count++;
  } while (value >>= 1);
  return width - count;
}


static int CountOneBits(uint64_t value, int width) {
  // Mask out unused bits to ensure that they are not counted.
  value &= (0xffffffffffffffffUL >> (64-width));

  value = ((value >> 1) & 0x5555555555555555) + (value & 0x5555555555555555);
  value = ((value >> 2) & 0x3333333333333333) + (value & 0x3333333333333333);
  value = ((value >> 4) & 0x0f0f0f0f0f0f0f0f) + (value & 0x0f0f0f0f0f0f0f0f);
  value = ((value >> 8) & 0x00ff00ff00ff00ff) + (value & 0x00ff00ff00ff00ff);
  value = ((value >> 16) & 0x0000ffff0000ffff) + (value & 0x0000ffff0000ffff);
  value = ((value >> 32) & 0x00000000ffffffff) + (value & 0x00000000ffffffff);

  return value;
}


// Test if a given value can be encoded in the immediate field of a logical
// instruction.
// If it can be encoded, the function returns true, and values pointed to by n,
// imm_s and imm_r are updated with immediates encoded in the format required
// by the corresponding fields in the logical instruction.
// If it can't be encoded, the function returns false, and the operand is
// undefined.
bool Operand::IsImmLogical(uint64_t value, uint8_t width, Operand* imm_op) {
  ASSERT(imm_op != NULL);
  ASSERT((width == kWRegSizeInBits) || (width == kXRegSizeInBits));
  ASSERT((width == kXRegSizeInBits) || (value <= 0xffffffffUL));
  uint8_t n = 0;
  uint8_t imm_s = 0;
  uint8_t imm_r = 0;

  // Logical immediates are encoded using parameters n, imm_s and imm_r using
  // the following table:
  //
  //  N   imms    immr    size        S             R
  //  1  ssssss  rrrrrr    64    UInt(ssssss)  UInt(rrrrrr)
  //  0  0sssss  xrrrrr    32    UInt(sssss)   UInt(rrrrr)
  //  0  10ssss  xxrrrr    16    UInt(ssss)    UInt(rrrr)
  //  0  110sss  xxxrrr     8    UInt(sss)     UInt(rrr)
  //  0  1110ss  xxxxrr     4    UInt(ss)      UInt(rr)
  //  0  11110s  xxxxxr     2    UInt(s)       UInt(r)
  // (s bits must not be all set)
  //
  // A pattern is constructed of size bits, where the least significant S+1
  // bits are set. The pattern is rotated right by R, and repeated across a
  // 32 or 64-bit value, depending on destination register width.
  //
  // To test if an arbitrary immediate can be encoded using this scheme, an
  // iterative algorithm is used.

  // 1. If the value has all set or all clear bits, it can't be encoded.
  if ((value == 0) || (value == 0xffffffffffffffffULL) ||
      ((width == kWRegSizeInBits) && (value == 0xffffffff))) {
    return false;
  }

  int lead_zero = CountLeadingZeros(value, width);
  int lead_one = CountLeadingZeros(~value, width);
  int trail_zero = Utils::CountTrailingZeros(value);
  int trail_one = Utils::CountTrailingZeros(~value);
  int set_bits = CountOneBits(value, width);

  // The fixed bits in the immediate s field.
  // If width == 64 (X reg), start at 0xFFFFFF80.
  // If width == 32 (W reg), start at 0xFFFFFFC0, as the iteration for 64-bit
  // widths won't be executed.
  int imm_s_fixed = (width == kXRegSizeInBits) ? -128 : -64;
  int imm_s_mask = 0x3F;

  for (;;) {
    // 2. If the value is two bits wide, it can be encoded.
    if (width == 2) {
      n = 0;
      imm_s = 0x3C;
      imm_r = (value & 3) - 1;
      *imm_op = Operand(n, imm_s, imm_r);
      return true;
    }

    n = (width == 64) ? 1 : 0;
    imm_s = ((imm_s_fixed | (set_bits - 1)) & imm_s_mask);
    if ((lead_zero + set_bits) == width) {
      imm_r = 0;
    } else {
      imm_r = (lead_zero > 0) ? (width - trail_zero) : lead_one;
    }

    // 3. If the sum of leading zeros, trailing zeros and set bits is equal to
    //    the bit width of the value, it can be encoded.
    if (lead_zero + trail_zero + set_bits == width) {
      *imm_op = Operand(n, imm_s, imm_r);
      return true;
    }

    // 4. If the sum of leading ones, trailing ones and unset bits in the
    //    value is equal to the bit width of the value, it can be encoded.
    if (lead_one + trail_one + (width - set_bits) == width) {
      *imm_op = Operand(n, imm_s, imm_r);
      return true;
    }

    // 5. If the most-significant half of the bitwise value is equal to the
    //    least-significant half, return to step 2 using the least-significant
    //    half of the value.
    uint64_t mask = (1UL << (width >> 1)) - 1;
    if ((value & mask) == ((value >> (width >> 1)) & mask)) {
      width >>= 1;
      set_bits >>= 1;
      imm_s_fixed >>= 1;
      continue;
    }

    // 6. Otherwise, the value can't be encoded.
    return false;
  }
}


void Assembler::LoadWordFromPoolOffset(Register dst, Register pp,
                                       uint32_t offset) {
  ASSERT(dst != pp);
  if (Address::CanHoldOffset(offset)) {
    ldr(dst, Address(pp, offset));
  } else {
    const uint16_t offset_low = Utils::Low16Bits(offset);
    const uint16_t offset_high = Utils::High16Bits(offset);
    movz(dst, offset_low, 0);
    if (offset_high != 0) {
      movk(dst, offset_high, 1);
    }
    ldr(dst, Address(pp, dst));
  }
}


intptr_t Assembler::FindObject(const Object& obj, Patchability patchable) {
  // The object pool cannot be used in the vm isolate.
  ASSERT(Isolate::Current() != Dart::vm_isolate());
  ASSERT(!object_pool_.IsNull());

  // If the object is not patchable, check if we've already got it in the
  // object pool.
  if (patchable == kNotPatchable) {
    // Special case for Object::null(), which is always at object_pool_ index 0
    // because Lookup() below returns 0 when the object is not mapped in the
    // table.
    if (obj.raw() == Object::null()) {
      return 0;
    }

    intptr_t idx = object_pool_index_table_.Lookup(obj.raw());
    if (idx != 0) {
      ASSERT(patchable_pool_entries_[idx] == kNotPatchable);
      return idx;
    }
  }

  object_pool_.Add(obj, Heap::kOld);
  patchable_pool_entries_.Add(patchable);
  if (patchable == kNotPatchable) {
    // The object isn't patchable. Record the index for fast lookup.
    object_pool_index_table_.Insert(
        ObjIndexPair(obj.raw(), object_pool_.Length() - 1));
  }
  return object_pool_.Length() - 1;
}


intptr_t Assembler::FindImmediate(int64_t imm) {
  ASSERT(Isolate::Current() != Dart::vm_isolate());
  ASSERT(!object_pool_.IsNull());
  const Smi& smi = Smi::Handle(reinterpret_cast<RawSmi*>(imm));
  return FindObject(smi, kNotPatchable);
}


bool Assembler::CanLoadObjectFromPool(const Object& object) {
  // TODO(zra, kmillikin): Also load other large immediates from the object
  // pool
  if (object.IsSmi()) {
    // If the raw smi does not fit into a 32-bit signed int, then we'll keep
    // the raw value in the object pool.
    return !Utils::IsInt(32, reinterpret_cast<int64_t>(object.raw()));
  }
  ASSERT(object.IsNotTemporaryScopedHandle());
  ASSERT(object.IsOld());
  return (Isolate::Current() != Dart::vm_isolate()) &&
         // Not in the VMHeap, OR is one of the VMHeap objects we put in every
         // object pool.
         // TODO(zra): Evaluate putting all VM heap objects into the pool.
         (!object.InVMHeap() || (object.raw() == Object::null()) ||
                                (object.raw() == Bool::True().raw()) ||
                                (object.raw() == Bool::False().raw()));
}


bool Assembler::CanLoadImmediateFromPool(int64_t imm, Register pp) {
  return !Utils::IsInt(32, imm) &&
         (pp != kNoRegister) &&
         (Isolate::Current() != Dart::vm_isolate());
}


void Assembler::LoadObject(Register dst, const Object& object, Register pp) {
  if (CanLoadObjectFromPool(object)) {
    const int32_t offset =
        Array::element_offset(FindObject(object, kNotPatchable));
    LoadWordFromPoolOffset(dst, pp, offset - kHeapObjectTag);
  } else {
    ASSERT((Isolate::Current() == Dart::vm_isolate()) ||
           object.IsSmi() ||
           object.InVMHeap());
    LoadImmediate(dst, reinterpret_cast<int64_t>(object.raw()), pp);
  }
}


void Assembler::LoadImmediate(Register reg, int64_t imm, Register pp) {
  Comment("LoadImmediate");
  if (CanLoadImmediateFromPool(imm, pp)) {
    // It's a 64-bit constant and we're not in the VM isolate, so load from
    // object pool.
    // Save the bits that must be masked-off for the SmiTag
    int64_t val_smi_tag = imm & kSmiTagMask;
    imm &= ~kSmiTagMask;  // Mask off the tag bits.
    const int32_t offset = Array::element_offset(FindImmediate(imm));
    LoadWordFromPoolOffset(reg, pp, offset - kHeapObjectTag);
    if (val_smi_tag != 0) {
      // Add back the tag bits.
      orri(reg, reg, val_smi_tag);
    }
  } else {
    // 1. Can we use one orri operation?
    Operand op;
    Operand::OperandType ot;
    ot = Operand::CanHold(imm, kXRegSizeInBits, &op);
    if (ot == Operand::BitfieldImm) {
      orri(reg, ZR, imm);
      return;
    }

    // 2. Fall back on movz, movk, movn.
    const uint32_t w0 = Utils::Low32Bits(imm);
    const uint32_t w1 = Utils::High32Bits(imm);
    const uint16_t h0 = Utils::Low16Bits(w0);
    const uint16_t h1 = Utils::High16Bits(w0);
    const uint16_t h2 = Utils::Low16Bits(w1);
    const uint16_t h3 = Utils::High16Bits(w1);

    // Special case for w1 == 0xffffffff
    if (w1 == 0xffffffff) {
      if (h1 == 0xffff) {
        movn(reg, ~h0, 0);
      } else {
        movn(reg, ~h1, 1);
        movk(reg, h0, 0);
      }
      return;
    }

    // Special case for h3 == 0xffff
    if (h3 == 0xffff) {
      // We know h2 != 0xffff.
      movn(reg, ~h2, 2);
      if (h1 != 0xffff) {
        movk(reg, h1, 1);
      }
      if (h0 != 0xffff) {
        movk(reg, h0, 0);
      }
      return;
    }

    bool initialized = false;
    if (h0 != 0) {
      movz(reg, h0, 0);
      initialized = true;
    }
    if (h1 != 0) {
      if (initialized) {
        movk(reg, h1, 1);
      } else {
        movz(reg, h1, 1);
        initialized = true;
      }
    }
    if (h2 != 0) {
      if (initialized) {
        movk(reg, h2, 2);
      } else {
        movz(reg, h2, 2);
        initialized = true;
      }
    }
    if (h3 != 0) {
      if (initialized) {
        movk(reg, h3, 3);
      } else {
        movz(reg, h3, 3);
      }
    }
  }
}

}  // namespace dart

#endif  // defined TARGET_ARCH_ARM64

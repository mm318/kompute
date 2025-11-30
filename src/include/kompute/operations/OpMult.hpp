// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cassert>
#include <fstream>

#include "kompute/Core.hpp"

#include "ShaderOpMult.h"

#include "kompute/Algorithm.hpp"
#include "kompute/Tensor.hpp"

#include "kompute/operations/OpAlgoDispatch.hpp"

namespace kp {

/**
 * Operation that performs multiplication on two tensors and outpus on third
 * tensor.
 */
class OpMult : public OpAlgoDispatch
{
  public:
    /**
     * Default constructor with parameters that provides the bare minimum
     * requirements for the operations to be able to create and manage their
     * sub-components.
     *
     * @param memObjects Memory objects that are to be used in this operation
     * @param algorithm An algorithm that will be overridden with the OpMult
     * shader data and the tensors provided which are expected to be 3
     */
    OpMult(std::vector<std::shared_ptr<Memory>> memObjects,
           std::shared_ptr<Algorithm> algorithm)
      : OpAlgoDispatch(algorithm)
    {
        KP_LOG_DEBUG("Kompute OpMult constructor with params");

        if (memObjects.size() != 3) {
            throw std::runtime_error(
              "Kompute OpMult expected 3 mem objects but got " +
              std::to_string(memObjects.size()));
        }

        assert(SHADEROPMULT_COMP_SPV_SIZE % sizeof(uint32_t) == 0);
        std::vector<uint32_t> spirv(SHADEROPMULT_COMP_SPV_SIZE / sizeof(uint32_t));
        std::memcpy(spirv.data(), SHADEROPMULT_COMP_SPV_DATA, SHADEROPMULT_COMP_SPV_SIZE);

        algorithm->rebuild<>(memObjects, spirv);
    }

    /**
     * @brief Make OpMult non-copyable
     *
     */
    OpMult(const OpMult&) = delete;
    OpMult(const OpMult&&) = delete;
    OpMult& operator=(const OpMult&) = delete;
    OpMult& operator=(const OpMult&&) = delete;

    /**
     * Default destructor, which is in charge of destroying the algorithm
     * components but does not destroy the underlying tensors
     */
    ~OpMult() noexcept override { KP_LOG_DEBUG("Kompute OpMult destructor started"); }
};

} // End namespace kp

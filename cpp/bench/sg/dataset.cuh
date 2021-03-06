/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <common/cudart_utils.h>
#include <cuda_utils.h>
#include <linalg/transpose.h>
#include <random/make_blobs.h>
#include <random/make_regression.h>
#include <common/cumlHandle.hpp>
#include <cuml/cuml.hpp>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace ML {
namespace Bench {

/**
 * Indicates the dataset size. This is supposed to be used as the base class
 * by every Benchmark's Params structure.
 */
struct DatasetParams {
  /** number of rows in the datset */
  int nrows;
  /** number of cols in the dataset */
  int ncols;
  /** number of classes in the dataset (useless for regression cases) */
  int nclasses;
  /** input dataset is stored row or col major? */
  bool rowMajor;
};

/** Holds params needed to generate blobs dataset */
struct BlobsParams {
  double cluster_std;
  bool shuffle;
  double center_box_min, center_box_max;
  uint64_t seed;
};

/** Holds params needed to generate regression dataset */
struct RegressionParams {
  int n_informative;
  int effective_rank;
  double bias;
  double tail_strength;
  double noise;
  bool shuffle;
  uint64_t seed;
};

/**
 * @brief A simple object to hold the loaded dataset for benchmarking
 * @tparam D type of the dataset (type of X)
 * @tparam L type of the labels/output (type of y)
 */
template <typename D, typename L>
struct Dataset {
  /** input data */
  D* X;
  /** labels or output associated with each row of input data */
  L* y;

  /** allocate space needed for the dataset */
  void allocate(const cumlHandle& handle, const DatasetParams& p) {
    auto allocator = handle.getDeviceAllocator();
    auto stream = handle.getStream();
    X = (D*)allocator->allocate(p.nrows * p.ncols * sizeof(D), stream);
    y = (L*)allocator->allocate(p.nrows * sizeof(L), stream);
  }

  /** free-up the buffers */
  void deallocate(const cumlHandle& handle, const DatasetParams& p) {
    auto allocator = handle.getDeviceAllocator();
    auto stream = handle.getStream();
    allocator->deallocate(X, p.nrows * p.ncols * sizeof(D), stream);
    allocator->deallocate(y, p.nrows * sizeof(L), stream);
  }

  /** whether the current dataset is for classification or regression */
  bool isClassification() const { return typeid(D) != typeid(L); }

  /**
   * Generate random blobs data. Args are the same as in make_blobs.
   * Assumes that the user has already called `allocate`
   */
  void blobs(const cumlHandle& handle, const DatasetParams& p,
             const BlobsParams& b) {
    ASSERT(isClassification(),
           "make_blobs: is only for classification/clustering problems!");
    const auto& handle_impl = handle.getImpl();
    auto stream = handle_impl.getStream();
    auto cublas_handle = handle_impl.getCublasHandle();
    auto allocator = handle_impl.getDeviceAllocator();

    D* tmpX = X;

    if (!p.rowMajor) {
      tmpX = (D*)allocator->allocate(p.nrows * p.ncols * sizeof(D), stream);
    }
    MLCommon::Random::make_blobs<D, L>(
      tmpX, y, p.nrows, p.ncols, p.nclasses, allocator, stream, nullptr,
      nullptr, D(b.cluster_std), b.shuffle, D(b.center_box_min),
      D(b.center_box_max), b.seed);
    if (!p.rowMajor) {
      MLCommon::LinAlg::transpose(tmpX, X, p.nrows, p.ncols, cublas_handle,
                                  stream);
      allocator->deallocate(tmpX, p.nrows * p.ncols * sizeof(D), stream);
    }
  }

  /**
   * Generate random regression data. Args are the same as in make_regression.
   * Assumes that the user has already called `allocate`
   */
  void regression(const cumlHandle& handle, const DatasetParams& p,
                  const RegressionParams& r) {
    ASSERT(!isClassification(),
           "make_regression: is only for regression problems!");
    const auto& handle_impl = handle.getImpl();
    auto stream = handle_impl.getStream();
    auto cublas_handle = handle_impl.getCublasHandle();
    auto cusolver_handle = handle_impl.getcusolverDnHandle();
    auto allocator = handle_impl.getDeviceAllocator();

    D* tmpX = X;

    if (!p.rowMajor) {
      tmpX = (D*)allocator->allocate(p.nrows * p.ncols * sizeof(D), stream);
    }
    MLCommon::Random::make_regression(
      tmpX, y, p.nrows, p.ncols, r.n_informative, cublas_handle,
      cusolver_handle, allocator, stream, (D*)nullptr, 1, D(r.bias),
      r.effective_rank, D(r.tail_strength), D(r.noise), r.shuffle, r.seed);
    if (!p.rowMajor) {
      MLCommon::LinAlg::transpose(tmpX, X, p.nrows, p.ncols, cublas_handle,
                                  stream);
      allocator->deallocate(tmpX, p.nrows * p.ncols * sizeof(D), stream);
    }
  }

  /**
   * @brief Read the input csv file and construct the dataset.
   *        Assumes that the user has already called `allocate`
   * @tparam Lambda lambda to customize how to read the data and labels
   * @param handle cuml handle
   * @param csvfile the csv file
   * @param p dataset parameters
   * @param readOp functor/operator to take the current row of values and update
   *               the dataset accordingly. Its signature is expected to be:
   * `void readOp(const std::vector<std::string>& row, std::vector<D>& X,
   *              std::vector<L>& y, int lineNum, const DatasetParams& p);`
   */
  template <typename Lambda>
  void read_csv(const cumlHandle& handle, const std::string& csvfile,
                const DatasetParams& p, Lambda readOp) {
    if (isClassification() && p.nclasses <= 0) {
      ASSERT(false,
             "read_csv: for classification data 'nclasses' is mandatory!");
    }
    std::vector<D> _X(p.nrows * p.ncols);
    std::vector<L> _y(p.nrows);
    std::ifstream myfile;
    myfile.open(csvfile);
    std::string line;
    int counter = 0;
    int break_cnt = p.nrows;
    while (getline(myfile, line) && (counter < p.nrows)) {
      auto row = split(line, ',');
      readOp(row, _X, _y, counter, p);
      counter++;
    }
    myfile.close();
    auto stream = handle.getStream();
    MLCommon::copy(X, &(_X[0]), p.nrows * p.ncols, stream);
    MLCommon::copy(y, &(_y[0]), p.nrows, stream);
  }

 private:
  std::vector<std::string> split(const std::string& str, char delimiter) {
    std::vector<std::string> tokens;
    std::string token;
    std::istringstream iss(str);
    while (std::getline(iss, token, delimiter)) {
      tokens.push_back(token);
    }
    return tokens;
  }
};

}  // end namespace Bench
}  // end namespace ML

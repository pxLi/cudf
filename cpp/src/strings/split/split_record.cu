/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/get_value.cuh>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/strings/detail/strings_column_factories.cuh>
#include <cudf/strings/split/split.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <strings/split/split_utils.cuh>

#include <thrust/scan.h>
#include <thrust/transform.h>

namespace cudf {
namespace strings {
namespace detail {

using string_index_pair = thrust::pair<const char*, size_type>;

namespace {

enum class Dir { FORWARD, BACKWARD };

/**
 * @brief Compute the number of tokens for the `idx'th` string element of `d_strings`.
 */
template <Dir dir>
struct token_counter_fn {
  column_device_view const d_strings;  // strings to split
  string_view const d_delimiter;       // delimiter for split
  size_type const max_tokens = std::numeric_limits<size_type>::max();

  __device__ size_type operator()(size_type idx) const
  {
    if (d_strings.is_null(idx)) { return 0; }

    auto const d_str      = d_strings.element<string_view>(idx);
    size_type token_count = 0;
    size_type start_pos   = 0;               // updates only if moving forward
    size_type end_pos     = d_str.length();  // updates only if moving backward
    while (token_count < max_tokens - 1) {
      auto const delimiter_pos = dir == Dir::FORWARD ? d_str.find(d_delimiter, start_pos)
                                                     : d_str.rfind(d_delimiter, start_pos, end_pos);
      if (delimiter_pos < 0) break;
      token_count++;
      if (dir == Dir::FORWARD)
        start_pos = delimiter_pos + d_delimiter.length();
      else
        end_pos = delimiter_pos;
    }
    return token_count + 1;  // always at least one token
  }
};

/**
 * @brief Identify the tokens from the `idx'th` string element of `d_strings`.
 */
template <Dir dir>
struct token_reader_fn {
  column_device_view const d_strings;  // strings to split
  string_view const d_delimiter;       // delimiter for split
  int32_t* d_token_offsets{};          // for locating tokens in d_tokens
  string_index_pair* d_tokens{};

  template <bool last>
  __device__ string_index_pair resolve_token(string_view const& d_str,
                                             size_type start_pos,
                                             size_type end_pos,
                                             size_type delimiter_pos) const
  {
    if (last) {
      auto const src_byte_offset  = dir == Dir::FORWARD ? d_str.byte_offset(start_pos) : 0;
      auto const token_char_bytes = dir == Dir::FORWARD
                                      ? d_str.byte_offset(end_pos) - src_byte_offset
                                      : d_str.byte_offset(end_pos);
      return string_index_pair{d_str.data() + src_byte_offset, token_char_bytes};
    } else {
      auto const src_byte_offset = dir == Dir::FORWARD
                                     ? d_str.byte_offset(start_pos)
                                     : d_str.byte_offset(delimiter_pos + d_delimiter.length());
      auto const token_char_bytes = dir == Dir::FORWARD
                                      ? d_str.byte_offset(delimiter_pos) - src_byte_offset
                                      : d_str.byte_offset(end_pos) - src_byte_offset;
      return string_index_pair{d_str.data() + src_byte_offset, token_char_bytes};
    }
  }

  __device__ void operator()(size_type idx)
  {
    if (d_strings.is_null(idx)) { return; }

    auto const token_offset = d_token_offsets[idx];
    auto const token_count  = d_token_offsets[idx + 1] - token_offset;
    auto d_result           = d_tokens + token_offset;
    auto const d_str        = d_strings.element<string_view>(idx);
    if (d_str.empty()) {
      *d_result = string_index_pair{"", 0};
      return;
    }

    size_type token_idx = 0;
    size_type start_pos = 0;               // updates only if moving forward
    size_type end_pos   = d_str.length();  // updates only if moving backward
    while (token_idx < token_count - 1) {
      auto const delimiter_pos = dir == Dir::FORWARD ? d_str.find(d_delimiter, start_pos)
                                                     : d_str.rfind(d_delimiter, start_pos, end_pos);
      if (delimiter_pos < 0) break;
      auto const token = resolve_token<false>(d_str, start_pos, end_pos, delimiter_pos);
      if (dir == Dir::FORWARD)
        d_result[token_idx] = token;
      else
        d_result[token_count - 1 - token_idx] = token;

      token_idx++;
      if (dir == Dir::FORWARD)
        start_pos = delimiter_pos + d_delimiter.length();
      else
        end_pos = delimiter_pos;
    }

    auto const last_token = resolve_token<true>(d_str, start_pos, end_pos, -1);
    if (dir == Dir::FORWARD)
      d_result[token_idx] = last_token;
    else
      d_result[0] = last_token;
  }
};

/**
 * @brief Compute the number of tokens for the `idx'th` string element of `d_strings`.
 */
struct whitespace_token_counter_fn {
  column_device_view const d_strings;  // strings to split
  size_type const max_tokens = std::numeric_limits<size_type>::max();

  __device__ size_type operator()(size_type idx) const
  {
    if (d_strings.is_null(idx)) { return 0; }

    auto const d_str        = d_strings.element<string_view>(idx);
    size_type token_count   = 0;
    auto spaces             = true;
    auto reached_max_tokens = false;
    for (auto ch : d_str) {
      if (spaces != (ch <= ' ')) {
        if (!spaces) {
          if (token_count < max_tokens - 1) {
            token_count++;
          } else {
            reached_max_tokens = true;
            break;
          }
        }
        spaces = !spaces;
      }
    }
    // pandas.Series.str.split("") returns 0 tokens.
    if (reached_max_tokens || !spaces) token_count++;
    return token_count;
  }
};

/**
 * @brief Identify the tokens from the `idx'th` string element of `d_strings`.
 */
template <Dir dir>
struct whitespace_token_reader_fn {
  column_device_view const d_strings;  // strings to split
  size_type const max_tokens{};
  int32_t* d_token_offsets{};
  string_index_pair* d_tokens{};

  __device__ void operator()(size_type idx)
  {
    auto const token_offset = d_token_offsets[idx];
    auto const token_count  = d_token_offsets[idx + 1] - token_offset;
    if (token_count == 0) { return; }
    auto d_result = d_tokens + token_offset;

    auto const d_str = d_strings.element<string_view>(idx);
    whitespace_string_tokenizer tokenizer(d_str, dir != Dir::FORWARD);
    size_type token_idx = 0;
    string_view last_token{};
    if (dir == Dir::FORWARD) {
      while (tokenizer.next_token() && (token_idx < token_count)) {
        last_token            = tokenizer.get_token();
        d_result[token_idx++] = string_index_pair{last_token.data(), last_token.size_bytes()};
      }
      if (token_count == max_tokens) {
        d_result[token_idx - 1] = string_index_pair{
          last_token.data(),
          static_cast<size_type>(d_str.data() + d_str.size_bytes() - last_token.data())};
      }
    } else {
      while (tokenizer.prev_token() && (token_idx < token_count)) {
        last_token = tokenizer.get_token();
        d_result[token_count - 1 - token_idx] =
          string_index_pair{last_token.data(), last_token.size_bytes()};
        ++token_idx;
      }
      if (token_count == max_tokens) {
        --token_idx;
        d_result[token_count - 1 - token_idx] = string_index_pair{
          d_str.data(),
          static_cast<size_type>(last_token.data() + last_token.size_bytes() - d_str.data())};
      }
    }
  }
};

}  // namespace

// The output is one list item per string
template <typename TokenCounter, typename TokenReader>
std::unique_ptr<column> split_record_fn(strings_column_view const& strings,
                                        TokenCounter counter,
                                        TokenReader reader,
                                        rmm::mr::device_memory_resource* mr,
                                        cudaStream_t stream)
{
  // create offsets column by counting the number of tokens per string
  auto strings_count = strings.size();
  auto offsets       = make_numeric_column(
    data_type{type_id::INT32}, strings_count + 1, mask_state::UNALLOCATED, stream, mr);
  auto d_offsets = offsets->mutable_view().data<int32_t>();
  thrust::transform(rmm::exec_policy(stream)->on(stream),
                    thrust::make_counting_iterator(0),
                    thrust::make_counting_iterator(strings_count),
                    d_offsets,
                    counter);
  thrust::exclusive_scan(
    rmm::exec_policy(stream)->on(stream), d_offsets, d_offsets + strings_count + 1, d_offsets);

  // last entry is the total number of tokens to be generated
  auto total_tokens = cudf::detail::get_value<int32_t>(offsets->view(), strings_count, stream);
  // split each string into an array of index-pair values
  rmm::device_vector<string_index_pair> tokens(total_tokens);
  reader.d_token_offsets = d_offsets;
  reader.d_tokens        = tokens.data().get();
  thrust::for_each_n(rmm::exec_policy(stream)->on(stream),
                     thrust::make_counting_iterator<size_type>(0),
                     strings_count,
                     reader);
  // convert the index-pairs into one big strings column
  auto strings_output = make_strings_column(tokens.begin(), tokens.end(), mr, stream);
  // create a lists column using the offsets and the strings columns
  return make_lists_column(strings_count,
                           std::move(offsets),
                           std::move(strings_output),
                           strings.null_count(),
                           copy_bitmask(strings.parent(), stream, mr));
}

template <Dir dir>
std::unique_ptr<column> split_record(
  strings_column_view const& strings,
  string_scalar const& delimiter      = string_scalar(""),
  size_type maxsplit                  = -1,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
  cudaStream_t stream                 = 0)
{
  CUDF_EXPECTS(delimiter.is_valid(), "Parameter delimiter must be valid");

  // makes consistent with Pandas
  size_type max_tokens = maxsplit > 0 ? maxsplit + 1 : std::numeric_limits<size_type>::max();

  auto d_strings_column_ptr = column_device_view::create(strings.parent(), stream);
  if (delimiter.size() == 0) {
    return split_record_fn(strings,
                           whitespace_token_counter_fn{*d_strings_column_ptr, max_tokens},
                           whitespace_token_reader_fn<dir>{*d_strings_column_ptr, max_tokens},
                           mr,
                           stream);
  } else {
    string_view d_delimiter(delimiter.data(), delimiter.size());
    return split_record_fn(strings,
                           token_counter_fn<dir>{*d_strings_column_ptr, d_delimiter, max_tokens},
                           token_reader_fn<dir>{*d_strings_column_ptr, d_delimiter},
                           mr,
                           stream);
  }
}

}  // namespace detail

// external APIs

std::unique_ptr<column> split_record(strings_column_view const& strings,
                                     string_scalar const& delimiter,
                                     size_type maxsplit,
                                     rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::split_record<detail::Dir::FORWARD>(strings, delimiter, maxsplit, mr, 0);
}

std::unique_ptr<column> rsplit_record(strings_column_view const& strings,
                                      string_scalar const& delimiter,
                                      size_type maxsplit,
                                      rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::split_record<detail::Dir::BACKWARD>(strings, delimiter, maxsplit, mr, 0);
}

}  // namespace strings
}  // namespace cudf

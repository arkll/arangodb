// Copyright Louis Dionne 2013-2016
// Distributed under the Boost Software License, Version 1.0.
// (See accompanying file LICENSE.md or copy at http://boost.org/LICENSE_1_0.txt)

#include <tuple>


template <int>
struct x { };

int main() {
    constexpr auto tuple = std::make_tuple(
        <%= (1..input_size).map { |n| "x<#{n}>{}" }.join(', ') %>
    );
    constexpr auto result = std::get<<%= input_size-1 %>>(tuple);
    (void)result;
}

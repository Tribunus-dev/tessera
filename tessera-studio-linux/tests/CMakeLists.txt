cmake_minimum_required(VERSION 3.20)
add_executable(test_cli_resolver test_cli_resolver.cpp)
target_link_libraries(test_cli_resolver PRIVATE tessera-core-linux)
add_test(NAME cli_resolver COMMAND test_cli_resolver)

add_executable(test_provider test_provider.cpp)
target_link_libraries(test_provider PRIVATE tessera-core-linux)
add_test(NAME provider COMMAND test_provider)

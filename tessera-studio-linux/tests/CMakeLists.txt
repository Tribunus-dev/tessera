cmake_minimum_required(VERSION 3.20)
add_executable(test_cli_resolver test_cli_resolver.cpp)
target_link_libraries(test_cli_resolver PRIVATE tessera-core-linux)
add_test(NAME cli_resolver COMMAND test_cli_resolver)

add_executable(test_provider test_provider.cpp)
target_link_libraries(test_provider PRIVATE tessera-core-linux)
add_test(NAME provider COMMAND test_provider)

add_executable(test_capacity test_capacity.cpp)
target_link_libraries(test_capacity PRIVATE tessera-core-linux)
add_test(NAME capacity COMMAND test_capacity)

add_executable(test_moe test_moe.cpp)
target_link_libraries(test_moe PRIVATE tessera-core-linux)
add_test(NAME moe COMMAND test_moe)

add_executable(test_agent test_agent.cpp)
target_link_libraries(test_agent PRIVATE tessera-core-linux)
add_test(NAME agent COMMAND test_agent)

add_executable(test_tracestore test_tracestore.cpp)
target_link_libraries(test_tracestore PRIVATE tessera-core-linux)
add_test(NAME tracestore COMMAND test_tracestore)

add_executable(test_data_curation test_data_curation.cpp)
target_link_libraries(test_data_curation PRIVATE tessera-core-linux)
add_test(NAME data_curation COMMAND test_data_curation)

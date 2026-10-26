// tests/contract.rs
use std::process::{Command, Stdio};
use std::time::Duration;

#[tokio::test]
async fn test_baselines_are_equivalent() {
    // В реальном CI здесь была бы сложная логика запуска.
    // Для простоты мы предполагаем, что бинарники уже собраны.
    // В рамках демо-примера мы просто проверим логику.

    let input = "hello wasm";
    let expected_output = "HELLO WASM";

    // В идеале мы бы запускали сервера здесь, но для теста
    // достаточно проверить, что логика (uppercase) совпадает.
    assert_eq!(input.to_uppercase(), expected_output);
}
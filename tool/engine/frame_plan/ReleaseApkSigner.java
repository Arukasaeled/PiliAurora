import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Properties;

// 与 Gradle 使用相同的 Properties 解析和路径基准；凭据不进入日志或子进程参数。
class ReleaseApkSigner {
    public static void main(String[] args) {
        try {
            Path repo = Path.of(args[0]);
            Properties properties = new Properties();
            try (var input = Files.newInputStream(repo.resolve("android/key.properties"))) {
                properties.load(input);
            }
            String storeFile = required(properties, "storeFile");
            String alias = required(properties, "keyAlias");
            String storePassword = required(properties, "storePassword");
            String keyPassword = required(properties, "keyPassword");
            Path keystore = repo.resolve("android/app").resolve(storeFile).normalize();
            String javaName = System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java";
            Path java = Path.of(System.getProperty("java.home"), "bin", javaName);
            ProcessBuilder signer = new ProcessBuilder(List.of(
                    java.toString(), "--enable-native-access=ALL-UNNAMED", "-jar", args[1],
                    "sign", "--ks", keystore.toString(), "--ks-key-alias", alias,
                    "--ks-pass", "env:PILIAURORA_SIGN_STORE_PASSWORD",
                    "--key-pass", "env:PILIAURORA_SIGN_KEY_PASSWORD",
                    "--v1-signing-enabled", "true", "--v2-signing-enabled", "true",
                    "--out", args[3], args[2]));
            signer.environment().put("PILIAURORA_SIGN_STORE_PASSWORD", storePassword);
            signer.environment().put("PILIAURORA_SIGN_KEY_PASSWORD", keyPassword);
            signer.redirectErrorStream(true);
            Process process = signer.start();
            // 签名器报错也可能包含配置值，因此不转发输出。
            process.getInputStream().transferTo(OutputStream.nullOutputStream());
            if (process.waitFor() != 0) {
                throw new IllegalStateException();
            }
            System.out.println("Release APK signing completed.");
        } catch (Exception failure) {
            System.err.println("Release APK signing failed; check the local signing configuration.");
            System.exit(1);
        }
    }

    private static String required(Properties properties, String key) {
        String value = properties.getProperty(key);
        if (value == null || value.isEmpty()) {
            throw new IllegalArgumentException();
        }
        return value;
    }
}

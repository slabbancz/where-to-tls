package wheretotls;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

public final class ConfigLoader {
    private static final ObjectMapper JSON = new ObjectMapper()
            .enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);

    private ConfigLoader() {
    }

    public static ServerConfig load(Path path) throws IOException {
        ServerConfig config = JSON.readValue(Files.readAllBytes(path), ServerConfig.class);
        config.validate();
        return config;
    }
}

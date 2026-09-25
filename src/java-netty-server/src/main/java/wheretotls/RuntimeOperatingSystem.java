package wheretotls;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;

record RuntimeOperatingSystem(String name, String source) {
    static RuntimeOperatingSystem read() {
        String name = System.getProperty("os.name");
        if (!"Linux".equalsIgnoreCase(name)) {
            return new RuntimeOperatingSystem(name + " " + System.getProperty("os.version"),
                    "System.getProperty(os.name, os.version)");
        }
        try {
            return readLinux(Path.of("/etc/os-release"), Path.of("/usr/lib/os-release"));
        } catch (IOException exception) {
            throw new IllegalStateException("failed to read runtime OS evidence", exception);
        }
    }

    static RuntimeOperatingSystem readLinux(Path... paths) throws IOException {
        for (Path path : paths) {
            String contents;
            try {
                contents = Files.readString(path);
            } catch (NoSuchFileException exception) {
                continue;
            }
            return new RuntimeOperatingSystem(contents, path.toString());
        }
        return new RuntimeOperatingSystem("unexposed-by-runtime", "unexposed-by-runtime");
    }
}

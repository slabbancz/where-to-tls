package wheretotls;

import java.nio.file.Path;

public final class Program {
    private Program() {
    }

    public static void main(String[] args) {
        String configPath = "/etc/wtt/config.json";
        if (args.length == 2 && "--config".equals(args[0])) {
            configPath = args[1];
        } else if (args.length != 0) {
            fail("usage: java -jar server.jar [--config <path>]");
        }

        try {
            new NettyServer(ConfigLoader.load(Path.of(configPath))).run();
        } catch (Exception exception) {
            fail(exception.getMessage());
        }
    }

    private static void fail(String message) {
        System.err.printf("[java-netty-server] FATAL: %s%n", message);
        System.exit(1);
    }
}

package com.mcp.mcp_client.service;

import com.mcp.mcp_client.config.McpServerProperties;
import jakarta.annotation.PostConstruct;
import org.springframework.stereotype.Service;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.InetSocketAddress;
import java.net.Socket;

@Service
public class McpInspectorService {

    private final McpServerProperties properties;

    public McpInspectorService(McpServerProperties properties) {
        this.properties = properties;
    }

    @PostConstruct
    public void startAndInspectMcpServer() {
        String jarPath = properties.getJarPath();
        String host = properties.getHost();
        int port = properties.getPort();

        System.out.println("🔍 Starting MCP Server from: " + jarPath);

        try {
            ProcessBuilder pb = new ProcessBuilder("java", "-jar", jarPath);
            pb.redirectErrorStream(true);

            Process process = pb.start();

            new Thread(() -> {
                try (BufferedReader reader =
                             new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        System.out.println("[MCP SERVER] " + line);
                    }
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }).start();

            new Thread(() -> {
                boolean running = false;
                for (int i = 0; i < 30; i++) {
                    if (isPortOpen(host, port, 2000)) {
                        running = true;
                        break;
                    }
                    try {
                        Thread.sleep(1000);
                    } catch (InterruptedException ignored) {}
                }

                if (running) {
                    System.out.printf("✅ MCP Server is UP at http://%s:%d%n", host, port);
                } else {
                    System.err.printf("❌ MCP Server did not start or is unreachable at http://%s:%d%n", host, port);
                }
            }).start();

        } catch (Exception e) {
            throw new RuntimeException("❌ Failed to launch MCP server from " + jarPath, e);
        }
    }

    private boolean isPortOpen(String host, int port, int timeout) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(host, port), timeout);
            return true;
        } catch (Exception ex) {
            return false;
        }
    }
}

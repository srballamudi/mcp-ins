package com.mcp.mcp_client.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "mcp.server")
public class McpServerProperties {

    private String jarPath;
    private String host;
    private int port;

    public String getJarPath() {
        return jarPath;
    }
    public void setJarPath(String jarPath) {
        this.jarPath = jarPath;
    }
    public String getHost() {
        return host;
    }
    public void setHost(String host) {
        this.host = host;
    }
    public int getPort() {
        return port;
    }
    public void setPort(int port) {
        this.port = port;
    }
}

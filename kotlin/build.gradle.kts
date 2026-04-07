plugins {
    kotlin("jvm") version "2.0.21"
    kotlin("plugin.serialization") version "2.0.21"
    `maven-publish`
}

group = "dev.antidrift"
version = "0.1.1"

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}

kotlin {
    jvmToolchain(21)
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
            pom {
                name.set("zeromcp")
                description.set("Zero-config MCP runtime for Kotlin")
                url.set("https://github.com/antidrift-dev/zeromcp")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
                developers {
                    developer {
                        name.set("Antidrift")
                        email.set("hello@probeo.io")
                        organization.set("Antidrift")
                        organizationUrl.set("https://github.com/antidrift-dev")
                    }
                }
                scm {
                    connection.set("scm:git:git://github.com/antidrift-dev/zeromcp.git")
                    developerConnection.set("scm:git:ssh://github.com:antidrift-dev/zeromcp.git")
                    url.set("https://github.com/antidrift-dev/zeromcp/tree/main/kotlin")
                }
            }
        }
    }
}

pipelineJob('ci-application') {
    description('CI: validate, test, build and push images. Does not deploy.')
    logRotator { numToKeep(20) }
    properties {
        disableConcurrentBuilds()
    }
    triggers {
        githubPush()
    }
    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://github.com/ag139/project-part3.git')
                    }
                    branch('*/main')
                }
            }
            scriptPath('ci-Jenkinsfile')
            lightweight(false)
        }
    }
}

pipelineJob('cd-application') {
    description('CD: deploy an image tag already built and pushed by CI. Does not build.')
    logRotator { numToKeep(20) }
    properties {
        disableConcurrentBuilds()
    }
    parameters {
        stringParam('IMAGE_TAG', '', 'Immutable image tag produced by CI. latest is rejected.')
        stringParam('TARGET_NAMESPACE', 'devops-app', 'Target namespace for the deployment.')
        stringParam('CI_BUILD_NUMBER', '', 'CI build number, for traceability.')
    }
    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://github.com/ag139/project-part3.git')
                    }
                    branch('*/main')
                }
            }
            scriptPath('cd-Jenkinsfile')
            lightweight(false)
        }
    }
}

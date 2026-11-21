// Trusted local initialization. Never copy an existing Jenkins home into a release.
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.security.csrf.DefaultCrumbIssuer
import groovy.json.JsonOutput
import groovy.json.JsonSlurper

def j = Jenkins.get()
def root = new File(System.getenv('FAF_BUILD_HOME'))
def credentials = new File(j.rootDir, 'secrets/faf-portable-admin.json')
def existing = new JsonSlurper().parse(credentials)
if (!existing.user || !existing.token) {
    // Fresh accounts only; a later launch must never reset an existing password.
    // Jenkins can already have in-memory SYSTEM/anonymous users before this
    // hook. Only password-bearing local login accounts indicate prior setup.
    if (hudson.model.User.getAll().any { it.getProperty(HudsonPrivateSecurityRealm.Details.class) != null }) {
        throw new IllegalStateException('Existing users found without portable credentials; refusing to reset accounts.')
    }
    def bytes = new byte[24]
    new java.security.SecureRandom().nextBytes(bytes)
    def password = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    def realm = new HudsonPrivateSecurityRealm(false)
    j.setSecurityRealm(realm)
    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    strategy.setAllowAnonymousRead(false)
    j.setAuthorizationStrategy(strategy)
    j.setCrumbIssuer(new DefaultCrumbIssuer(true))
    def user = realm.createAccount('admin', password)
    def token = user.getProperty(jenkins.security.ApiTokenProperty.class).tokenStore.generateNewToken('faf-portable-local-shutdown')
    user.save()
    credentials.setText(JsonOutput.toJson([user:'admin',password:password,token:token.plainValue]), 'UTF-8')
    j.save()
}
// Normal restart preserves accounts, permissions and manually installed plugins.
if (!j.isUseSecurity()) { throw new IllegalStateException('Portable Jenkins requires authentication.') }
j.setNumExecutors(1)
j.setLabelString('windows-godot')
def loader = j.pluginManager.uberClassLoader
def workflowJob = loader.loadClass('org.jenkinsci.plugins.workflow.job.WorkflowJob')
def flowDefinition = loader.loadClass('org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition')
def job = j.getItem('faf-windows')
if (job == null) { job = j.createProject(workflowJob, 'faf-windows') }
if (!workflowJob.isInstance(job)) { throw new IllegalStateException('faf-windows must be a Pipeline job.') }
job.setDefinition(flowDefinition.getConstructor(String.class,Boolean.TYPE).newInstance(new File(root,'Jenkinsfile').getText('UTF-8'), true))
job.addProperty(new hudson.model.ParametersDefinitionProperty([
    new hudson.model.StringParameterDefinition('BUILD_BRANCH','','Local branch; leave empty to select during build.'),
    new hudson.model.ChoiceParameterDefinition('BUILD_MODE',['Debug','Release'] as String[],'Build mode'),
    new hudson.model.StringParameterDefinition('BUILD_VERSION','','Optional version'),
    new hudson.model.BooleanParameterDefinition('RUN_TESTS',true,'Run additional test suite')
]))
job.setDescription('FAF Windows build tool. Reads committed snapshots from the configured local repository.')
job.save()
def config = new JsonSlurper().parse(new File(root,'portable-config.json'))
jenkins.model.JenkinsLocationConfiguration.get().setUrl("http://127.0.0.1:${config.port}/")
j.setInstallState(jenkins.install.InstallState.INITIAL_SETUP_COMPLETED)
j.save()
new File(root,'runtime/portable-ready.json').setText(JsonOutput.toJson([schemaVersion:1,user:'admin',ready:true]),'UTF-8')

require_relative 'spec_helper'

describe "Custom configuration" do
  let(:pack) { LanguagePack::Base.new("/tmp") }

  context "when no build.yml is present." do
    it { expect(pack.custom_build_steps(:before_assets_precompile)).to eq [] }
    it { expect(pack.custom_process_types).to eq({}) }
    it { expect(pack.setup_custom_build_environment).to eq nil }
  end

  context "when a build.yml is present." do
      around do |example|
        File.open("build.yml", "w") do |f|
          f.write <<-YML
env:
  CUSTOM_ENV: 'yes'

process_types:
 solr: bundle exec sunspot:solr:start

steps:
  before_assets_precompile:
    - echo 'This should be echoed before asset precompilation.'
    - ls -lah .
YML
        end

        example.run

        File.delete("build.yml")
      end

    describe "custom_build_steps" do
      it "should return build steps for a certain hook." do
        expect(pack.custom_build_steps(:before_assets_precompile)).to eq([
          "echo 'This should be echoed before asset precompilation.'",
           "ls -lah ."
        ])
      end
    end

    describe "custom_process_types" do
      it "should return build steps for a certain hook." do
        expect(pack.custom_process_types).to eq({
          "solr" => "bundle exec sunspot:solr:start"
        })
      end
    end

    describe "setup_custom_build_environment" do
      before { pack.setup_custom_build_environment }
      it "should set the custom env vars from the yml." do
        expect(ENV['CUSTOM_ENV']).to eq 'yes'
      end
    end
  end
end
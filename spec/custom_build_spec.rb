require_relative 'spec_helper'

describe "Custom configuration" do
  let(:pack) { LanguagePack::Base.new("/tmp") }

  context "when no build.yml is present." do
    it { expect(pack.custom_build_steps(:before_assets_precompile)).to eq [] }
    it { expect(pack.set_custom_build_env).to eq nil }
  end

  context "when a build.yml is present." do
      around do |example|
        File.open("build.yml", "w") do |f|
          f.write <<-YML
env:
  CUSTOM_ENV: 'yes'

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

    describe "set_custom_build_env" do
      before { pack.set_custom_build_env }
      it "should set the custom env vars from the yml." do
        expect(ENV['CUSTOM_ENV']).to eq 'yes'
      end
    end
  end
end
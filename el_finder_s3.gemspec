# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'el_finder_s3/version'

Gem::Specification.new do |spec|
  spec.name = 'el_finder_s3'
  spec.license = ['MIT']

  spec.version = ElFinderS3::VERSION
  spec.authors = ['Araslanov Evgeny', 'Raúl Anatol']
  spec.email = ['evgeniy.araslanov@bia-tech.ru', 'raul@natol.es']

  spec.summary = %q{elFinder server side connector for Ruby, with an S3 aws service.}
  spec.description = %q{Ruby gem to provide server side connector to elFinder using AWS S3 like a container}
  spec.homepage = 'https://gitlab.dellin.ru/web-bia/el_finder_s3'

  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "http://rubygems.bia-tech.ru"
  else
    raise 'RubyGems 2.0 or newer is required to protect against public gem pushes.'
  end

  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency('image_size', '>= 1.0.0')
  spec.add_dependency('aws-sdk', '~> 2')
  spec.add_dependency('mini_magick', '~> 4.2')
  spec.add_dependency('cache', '~> 0.4')

  spec.add_development_dependency 'bundler', '~> 1.10'
  spec.add_development_dependency 'rake', '~> 10.0'
end
